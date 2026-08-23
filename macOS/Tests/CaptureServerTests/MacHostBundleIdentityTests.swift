import Foundation
import XCTest

/// Exercises the fresh host builder and bundle verifier against identity, layout, rpath, and
/// dependency mutations. Fixtures are temporary ad-hoc-signed bundles only.
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

    func testBuilderNormalizesRPathsAndVerifierRejectsBundleMutations() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "bundle")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let outputDirectory = temporaryRoot.appendingPathComponent("build")
        let prebuiltBinDirectory = Bundle(
            for: MacHostBundleIdentityTests.self
        ).bundleURL.deletingLastPathComponent()
        let pristineFramework = prebuiltBinDirectory.appendingPathComponent(
            "LiveKitWebRTC.framework"
        )
        let pristineVersionA = pristineFramework.appendingPathComponent("Versions/A")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: pristineVersionA,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["Headers", "LiveKitWebRTC", "Modules", "Resources", "Versions"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pristineVersionA.appendingPathComponent("_CodeSignature").path
            ),
            "The pristine SwiftPM LiveKitWebRTC 144.7559.11 artifact must be unsigned."
        )
        let pristinePrivacyManifest = pristineVersionA.appendingPathComponent(
            "Versions/A/Resources/PrivacyInfo.xcprivacy"
        )
        var pristinePrivacyIsDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pristinePrivacyManifest.path,
                isDirectory: &pristinePrivacyIsDirectory
            )
        )
        XCTAssertFalse(pristinePrivacyIsDirectory.boolValue)

        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_HOST_CODESIGN_IDENTITY"] = "-"
        environment["OPENSTEAMER_HOST_APP_OUTPUT_DIR"] = outputDirectory.path
        environment["OPENSTEAMER_HOST_PREBUILT_BIN_DIR"] = prebuiltBinDirectory.path
        environment["OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS"] = "1"
        environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_TEAM_ID")
        environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1")
        environment.removeValue(forKey: "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE")

        let builder = repositoryRoot.appendingPathComponent(
            "macOS/scripts/build-opensteamer-host-app.sh"
        )
        let build = try run(executable: builder, environment: environment)
        XCTAssertEqual(build.status, 0, build.diagnostic)
        let app = outputDirectory.appendingPathComponent("opensteamer Host.app")
        let executable = app.appendingPathComponent("Contents/MacOS/CaptureServer")
        let framework = app.appendingPathComponent(
            "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.path))
        let frameworkRoot = app.appendingPathComponent(
            "Contents/Frameworks/LiveKitWebRTC.framework"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: frameworkRoot.appendingPathComponent("Versions/A"),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["Headers", "LiveKitWebRTC", "Modules", "Resources", "Versions", "_CodeSignature"]
        )
        let expectedFrameworkAliases = [
            "LiveKitWebRTC": "Versions/Current/LiveKitWebRTC",
            "Headers": "Versions/Current/Headers",
            "Modules": "Versions/Current/Modules",
            "Resources": "Versions/Current/Resources",
            "Versions/Current": "A",
        ]
        for (alias, expectedTarget) in expectedFrameworkAliases {
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: frameworkRoot.appendingPathComponent(alias).path
            )
            XCTAssertEqual(target, expectedTarget)
        }
        let pinnedPrivacyManifest = frameworkRoot.appendingPathComponent(
            "Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pinnedPrivacyManifest.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: frameworkRoot.appendingPathComponent("Versions/A/Versions"),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["A"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: frameworkRoot.appendingPathComponent("Versions/A/Versions/A"),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["Resources"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: frameworkRoot.appendingPathComponent("Versions/A/Versions/A/Resources"),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            ["PrivacyInfo.xcprivacy"]
        )
        let hostArchitectures = try readArchitectures(executable)
        let frameworkArchitectures = try readArchitectures(framework)
        XCTAssertFalse(hostArchitectures.isEmpty)
        XCTAssertTrue(
            hostArchitectures.isSubset(of: frameworkArchitectures),
            "Framework slices \(frameworkArchitectures) must contain host slices \(hostArchitectures)."
        )
        XCTAssertTrue(frameworkArchitectures.isSubset(of: Set(["arm64", "x86_64"])))
        XCTAssertGreaterThanOrEqual(
            frameworkArchitectures.count,
            2,
            "The LiveKit verifier regression fixture must be a genuine multi-architecture binary."
        )
        let frameworkLoadCommands = try run(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-L", framework.path]
        )
        XCTAssertEqual(frameworkLoadCommands.status, 0, frameworkLoadCommands.diagnostic)
        let architectureHeaders = frameworkLoadCommands.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("(architecture ") && $0.hasSuffix("):") }
        XCTAssertEqual(
            architectureHeaders.count,
            frameworkArchitectures.count,
            "otool -L must expose one genuine header for every framework architecture slice."
        )
        for architecture in frameworkArchitectures {
            XCTAssertTrue(
                architectureHeaders.contains {
                    $0.contains("(architecture \(architecture)):")
                },
                "otool -L output lacks the \(architecture) architecture header."
            )
        }

        let rpaths = try readRPaths(executable)
        XCTAssertEqual(rpaths, ["@executable_path/../Frameworks"])
        XCTAssertFalse(rpaths.contains("/usr/lib/swift"))
        XCTAssertFalse(rpaths.contains("@loader_path"))
        XCTAssertFalse(rpaths.contains { $0.contains("Xcode.app") || $0.contains(".build") })

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-bundle.sh"
        )
        let positive = try run(executable: verifier, arguments: [app.path])
        XCTAssertEqual(positive.status, 0, positive.diagnostic)
        let noncanonicalRuntimeMode = try run(
            executable: verifier,
            arguments: ["--installed-runtime", app.path]
        )
        XCTAssertNotEqual(noncanonicalRuntimeMode.status, 0, noncanonicalRuntimeMode.diagnostic)
        XCTAssertTrue(
            noncanonicalRuntimeMode.standardError.contains(
                "--installed-runtime is restricted to '/Applications/opensteamer Host.app'"
            ),
            noncanonicalRuntimeMode.diagnostic
        )
        let exactRequirement = try run(
            executable: verifier,
            arguments: [app.path, "", executable.path]
        )
        XCTAssertEqual(exactRequirement.status, 0, exactRequirement.diagnostic)

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "display-name"
        ) { mutant in
            let edit = try self.run(
                executable: URL(fileURLWithPath: "/usr/libexec/PlistBuddy"),
                arguments: [
                    "-c",
                    "Set :CFBundleDisplayName Wrong Host",
                    mutant.appendingPathComponent("Contents/Info.plist").path,
                ]
            )
            XCTAssertEqual(edit.status, 0, edit.diagnostic)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "extra-rpath"
        ) { mutant in
            let edit = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/install_name_tool"),
                arguments: [
                    "-add_rpath",
                    "/usr/lib/swift",
                    mutant.appendingPathComponent("Contents/MacOS/CaptureServer").path,
                ]
            )
            XCTAssertEqual(edit.status, 0, edit.diagnostic)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "duplicate-reviewed-rpath"
        ) { mutant in
            let binary = mutant.appendingPathComponent("Contents/MacOS/CaptureServer")
            let temporaryRPath = "@executable_path/../FrameworkX"
            let edit = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/install_name_tool"),
                arguments: ["-add_rpath", temporaryRPath, binary.path]
            )
            XCTAssertEqual(edit.status, 0, edit.diagnostic)
            try self.replaceFirstEqualLengthBytes(
                in: binary,
                original: temporaryRPath,
                replacement: "@executable_path/../Frameworks"
            )
            XCTAssertEqual(
                try self.readRPaths(binary),
                ["@executable_path/../Frameworks", "@executable_path/../Frameworks"]
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "loader-rpath"
        ) { mutant in
            let edit = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/install_name_tool"),
                arguments: [
                    "-add_rpath",
                    "@loader_path",
                    mutant.appendingPathComponent("Contents/MacOS/CaptureServer").path,
                ]
            )
            XCTAssertEqual(edit.status, 0, edit.diagnostic)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "symlinked-macos"
        ) { mutant in
            let macOS = mutant.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let escaped = temporaryRoot.appendingPathComponent("escaped-macos", isDirectory: true)
            try FileManager.default.moveItem(at: macOS, to: escaped)
            try FileManager.default.createSymbolicLink(at: macOS, withDestinationURL: escaped)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "symlinked-framework-executable"
        ) { mutant in
            let binary = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
            )
            let moved = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC.real"
            )
            try FileManager.default.moveItem(at: binary, to: moved)
            try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: moved)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "missing-framework-alias"
        ) { mutant in
            try FileManager.default.removeItem(
                at: mutant.appendingPathComponent(
                    "Contents/Frameworks/LiveKitWebRTC.framework/Headers"
                )
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "real-entry-replaces-framework-alias"
        ) { mutant in
            let alias = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Modules"
            )
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "redirected-framework-alias"
        ) { mutant in
            let alias = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Resources"
            )
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: "Versions/Current/Headers"
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "extra-framework-alias"
        ) { mutant in
            try FileManager.default.createSymbolicLink(
                atPath: mutant.appendingPathComponent(
                    "Contents/Frameworks/LiveKitWebRTC.framework/Unexpected"
                ).path,
                withDestinationPath: "Versions/Current/Headers"
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "escaping-framework-alias"
        ) { mutant in
            let alias = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Headers"
            )
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: "/var/tmp"
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "extra-pinned-nested-resource",
            expectedDiagnostic: "framework pinned nested Resources layout differs"
        ) { mutant in
            try Data("unexpected".utf8).write(
                to: mutant.appendingPathComponent(
                    "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/Versions/A/Resources/Unexpected.txt"
                )
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "redirected-pinned-nested-version",
            expectedDiagnostic: "framework pinned nested Versions layout differs"
        ) { mutant in
            let nestedA = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/Versions/A"
            )
            let moved = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/Versions/A.real"
            )
            try FileManager.default.moveItem(at: nestedA, to: moved)
            try FileManager.default.createSymbolicLink(at: nestedA, withDestinationURL: moved)
            let values = try nestedA.resourceValues(forKeys: [.isSymbolicLinkKey])
            XCTAssertEqual(values.isSymbolicLink, true, "redirected nested version mutation was a no-op")
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: nestedA.path),
                moved.path,
                "redirected nested version mutation targeted the wrong entry"
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "hard-linked-pinned-privacy-manifest",
            expectedDiagnostic: "unsafe app-tree metadata: hardlink:"
        ) { mutant in
            let privacy = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy"
            )
            let secondLink = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/Versions/A/Resources/PrivacyInfo.second-link"
            )
            try FileManager.default.linkItem(at: privacy, to: secondLink)
            let linkCount = try run(
                executable: URL(fileURLWithPath: "/usr/bin/stat"),
                arguments: ["-f", "%l", privacy.path]
            )
            XCTAssertEqual(linkCount.status, 0, linkCount.diagnostic)
            XCTAssertEqual(
                linkCount.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                "2",
                "hard-linked privacy mutation did not create the intended inode alias"
            )
            XCTAssertEqual(try Data(contentsOf: privacy), try Data(contentsOf: secondLink))
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "hard-linked-framework-inner-executable",
            expectedDiagnostic: "unsafe app-tree metadata: hardlink:"
        ) { mutant in
            let binary = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC"
            )
            try FileManager.default.linkItem(
                at: binary,
                to: mutant.appendingPathComponent(
                    "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC.second-link"
                )
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "hard-linked-executable",
            expectedDiagnostic: "unsafe app-tree metadata: hardlink:"
        ) { mutant in
            let binary = mutant.appendingPathComponent("Contents/MacOS/CaptureServer")
            let unreviewedBinary = mutant.appendingPathComponent(
                "Contents/MacOS/CaptureServer.unreviewed"
            )
            try FileManager.default.copyItem(at: binary, to: unreviewedBinary)
            try FileManager.default.linkItem(
                at: unreviewedBinary,
                to: mutant.appendingPathComponent("Contents/MacOS/CaptureServer.unreviewed-link")
            )
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "quarantine-xattr"
        ) { mutant in
            let xattr = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-w", "com.apple.quarantine", "0081;fixture", mutant.path]
            )
            XCTAssertEqual(xattr.status, 0, xattr.diagnostic)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "symlink-quarantine-xattr",
            expectedDiagnostic: "app bundle contains extended attributes"
        ) { mutant in
            let frameworkAlias = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Headers"
            )
            let xattr = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-s", "-w", "com.apple.quarantine", "0081;fixture", frameworkAlias.path]
            )
            XCTAssertEqual(xattr.status, 0, xattr.diagnostic)
        }

        try assertMutationRejected(
            app: app,
            verifier: verifier,
            name: "wrong-framework-install-id",
            expectedDiagnostic: "framework install ID in slice"
        ) { mutant in
            let binary = mutant.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
            )
            let edit = try self.run(
                executable: URL(fileURLWithPath: "/usr/bin/install_name_tool"),
                arguments: [
                    "-id", "/usr/lib/libWrongInstallName.dylib",
                    "-change", "/usr/lib/libobjc.A.dylib",
                    "@rpath/LiveKitWebRTC.framework/LiveKitWebRTC",
                    binary.path,
                ]
            )
            XCTAssertEqual(edit.status, 0, edit.diagnostic)
        }
    }

    func testBuilderRejectsIndependentPristineLiveKitLayoutMutants() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "pristine-layout-mutants")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let originalBin = Bundle(
            for: MacHostBundleIdentityTests.self
        ).bundleURL.deletingLastPathComponent()
        let builder = repositoryRoot.appendingPathComponent(
            "macOS/scripts/build-opensteamer-host-app.sh"
        )

        func assertRejected(
            name: String,
            expectedDiagnostic: String,
            mutate: (URL) throws -> Void
        ) throws {
            let fixtureBin = temporaryRoot.appendingPathComponent("\(name)-bin")
            try FileManager.default.createDirectory(
                at: fixtureBin,
                withIntermediateDirectories: false
            )
            let captureSource = originalBin.appendingPathComponent("CaptureServer")
            try FileManager.default.copyItem(
                at: captureSource,
                to: fixtureBin.appendingPathComponent("CaptureServer")
            )
            let framework = fixtureBin.appendingPathComponent("LiveKitWebRTC.framework")
            let copy = try run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [
                    "--noqtn",
                    originalBin.appendingPathComponent("LiveKitWebRTC.framework").path,
                    framework.path,
                ]
            )
            XCTAssertEqual(copy.status, 0, copy.diagnostic)
            let before = try directoryShape(framework)
            try mutate(framework)
            let after = try directoryShape(framework)
            XCTAssertNotEqual(after, before, "\(name) mutation must change the pristine layout.")

            var environment = ProcessInfo.processInfo.environment
            environment["OPENSTEAMER_HOST_CODESIGN_IDENTITY"] = "-"
            environment["OPENSTEAMER_HOST_APP_OUTPUT_DIR"] = temporaryRoot
                .appendingPathComponent("\(name)-output").path
            environment["OPENSTEAMER_HOST_PREBUILT_BIN_DIR"] = fixtureBin.path
            environment["OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS"] = "1"
            environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_TEAM_ID")
            environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1")
            environment.removeValue(
                forKey: "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE"
            )
            let rejection = try run(executable: builder, environment: environment)
            XCTAssertNotEqual(rejection.status, 0, "\(name) false-passed.\n\(rejection.diagnostic)")
            XCTAssertTrue(
                rejection.standardError.contains(expectedDiagnostic),
                "\(name) failed at the wrong gate.\n\(rejection.diagnostic)"
            )
        }

        try assertRejected(
            name: "unexpected-pre-sign-code-signature",
            expectedDiagnostic: "pristine pre-sign version A layout differs"
        ) { framework in
            try FileManager.default.createDirectory(
                at: framework.appendingPathComponent("Versions/A/_CodeSignature"),
                withIntermediateDirectories: false
            )
        }
        try assertRejected(
            name: "missing-pinned-privacy",
            expectedDiagnostic: "pinned nested Resources layout is invalid"
        ) { framework in
            try FileManager.default.removeItem(
                at: framework.appendingPathComponent(
                    "Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy"
                )
            )
        }
        try assertRejected(
            name: "extra-pinned-privacy-sibling",
            expectedDiagnostic: "pinned nested Resources layout is invalid"
        ) { framework in
            try Data("unexpected".utf8).write(
                to: framework.appendingPathComponent(
                    "Versions/A/Versions/A/Resources/Unexpected.txt"
                )
            )
        }
        try assertRejected(
            name: "redirected-current-alias",
            expectedDiagnostic: "framework alias 'Versions/Current' targets"
        ) { framework in
            let current = framework.appendingPathComponent("Versions/Current")
            try FileManager.default.removeItem(at: current)
            try FileManager.default.createSymbolicLink(
                atPath: current.path,
                withDestinationPath: "B"
            )
        }
    }

    func testBuilderAndVerifierSourceContainFreshReleaseAndCompleteIdentityGates() throws {
        let builder = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/build-opensteamer-host-app.sh"
            ),
            encoding: .utf8
        )
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-bundle.sh"
            ),
            encoding: .utf8
        )
        for required in [
            "OPENSTEAMER_REQUIRE_FRESH_RELEASE",
            "-warnings-as-errors",
            "-Werror",
            "MACOSX_DEPLOYMENT_TARGET=14.0",
            "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1",
            "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE",
            "install_name_tool -delete_rpath",
            "@executable_path/../Frameworks",
            "find \"$WEBRTC_FRAMEWORK\" -type l",
            "framework pristine pre-sign version A layout differs",
            "framework post-sign version A layout differs",
            "framework architectures '$framework_arches' do not contain host slice",
        ] {
            XCTAssertTrue(builder.contains(required), "Builder lacks \(required)")
        }
        XCTAssertFalse(builder.contains("rm -rf"))
        for required in [
            "MINIMUM_MACOS_VERSION=\"14.0\"",
            "lipo -archs",
            "vtool -show-build",
            "host deployment target '$HOST_MIN_OS' is not exactly",
            "framework deployment target '$FRAMEWORK_MIN_OS' is newer than",
            "framework install ID",
            "install_ids_for",
            "`otool -L` emits one header and one complete load-command list per architecture slice",
            "must contain exactly one reviewed LiveKit install-name entry",
            "BEGIN { finding = \"\" }",
            "framework alias set differs from the exact reviewed set",
            "framework version A layout differs from the reviewed layout",
            "framework pinned nested Resources layout differs from the reviewed layout",
            "framework architectures '$FRAMEWORK_ARCHES' do not contain required host slice",
            "/usr/lib/swift/*.dylib",
            "framework symlink escapes its bundle",
            "app bundle contains extended attributes",
            "--installed-runtime",
            "installed app contains unreviewed extended attributes",
            "installed app com.apple.macl is not exactly 72 NUL bytes",
            "APP_ROOT_DEVICE_INODE",
            "/usr/bin/xattr -rs",
            "verify_xattr_policy",
            "INITIAL_XATTR_POLICY_SNAPSHOT",
            "app root or extended-attribute policy changed during signature verification",
            "XATTRS_AFTER",
            "MACL_HEX_AFTER",
            "LC_RPATH set must be exactly",
            "main executable designated requirement does not match",
        ] {
            XCTAssertTrue(verifier.contains(required), "Verifier lacks \(required)")
        }
        XCTAssertTrue(
            verifier.contains(
                "INSTALLED_RUNTIME_APP_PATH=\"/Applications/opensteamer Host.app\""
            )
        )
        XCTAssertTrue(verifier.contains("${#MACL_HEX} -eq 144"))
        XCTAssertTrue(verifier.contains("\"$MACL_HEX\" != *[!0]*"))
    }

    private func assertMutationRejected(
        app: URL,
        verifier: URL,
        name: String,
        expectedDiagnostic: String? = nil,
        mutate: (URL) throws -> Void
    ) throws {
        let parent = app.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mutant-\(name)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let mutant = parent.appendingPathComponent("opensteamer Host.app")
        let clone = try run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-cR", app.path, mutant.path]
        )
        XCTAssertEqual(clone.status, 0, clone.diagnostic)
        try mutate(mutant)
        let rejection = try run(executable: verifier, arguments: [mutant.path])
        XCTAssertNotEqual(rejection.status, 0, "\(name) false-passed.\n\(rejection.diagnostic)")
        if let expectedDiagnostic {
            XCTAssertTrue(
                rejection.standardError.contains(expectedDiagnostic),
                "\(name) did not fail at its mutation-specific gate.\n\(rejection.diagnostic)"
            )
        }
    }

    private func directoryShape(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        var entries: [String] = []
        while let value = enumerator.nextObject() as? URL {
            let relative = value.path.replacingOccurrences(
                of: root.path + "/",
                with: "",
                options: [.anchored]
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: value.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: value.path
                )
                entries.append("\(relative)|symlink|\(target)")
            } else if type == .typeDirectory {
                entries.append("\(relative)|directory")
            } else if type == .typeRegular {
                entries.append("\(relative)|file")
            } else {
                entries.append("\(relative)|other")
            }
        }
        return entries.sorted()
    }

    private func replaceFirstEqualLengthBytes(
        in file: URL,
        original: String,
        replacement: String
    ) throws {
        let originalBytes = Data(original.utf8)
        let replacementBytes = Data(replacement.utf8)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        )
        var data = try Data(contentsOf: file)
        let range = try XCTUnwrap(data.range(of: originalBytes))
        data.replaceSubrange(range, with: replacementBytes)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: file.path
        )
    }

    private func readArchitectures(_ executable: URL) throws -> Set<String> {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", executable.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return Set(result.standardOutput.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private func readRPaths(_ executable: URL) throws -> [String] {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-l", executable.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        var paths: [String] = []
        var expectsPath = false
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields == ["cmd", "LC_RPATH"] {
                expectsPath = true
            } else if expectsPath, fields.first == "path", fields.count >= 2 {
                paths.append(String(fields[1]))
                expectsPath = false
            }
        }
        return paths
    }

    private func makeTemporaryDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
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
        let directory = makeTemporaryDirectory(prefix: "process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: stdoutURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
