import Foundation
import XCTest

final class ProductionDriverV8ScriptContractTests: XCTestCase {
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

    private func executableMode(_ relativePath: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: repositoryRoot.appendingPathComponent(relativePath).path
        )
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func runScript(
        _ relativePath: String,
        arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent(relativePath)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    func testV8CandidatePreparerIsExactVersionedV7Derivation() throws {
        let v7 = try source(
            "macOS/VirtualAudioDriver/scripts/prepare-production-driver-candidate-v7.sh"
        )
        let v8 = try source(
            "macOS/VirtualAudioDriver/scripts/prepare-production-driver-candidate-v8.sh"
        )
        let expected = v7
            .replacingOccurrences(of: "production-driver-v7", with: "production-driver-v8")
            .replacingOccurrences(
                of: "OpensteamerVirtualMicrophone-v7",
                with: "OpensteamerVirtualMicrophone-v8"
            )
            .replacingOccurrences(
                of: "production-driver-package-v7",
                with: "production-driver-package-v8"
            )
            .replacingOccurrences(
                of: "candidate-publication-v7",
                with: "candidate-publication-v8"
            )
            .replacingOccurrences(
                of: "production-driver-candidate.v7",
                with: "production-driver-candidate.v8"
            )
            .replacingOccurrences(
                of: "parse-installer-signature-v7.sh",
                with: "parse-installer-signature-v8.sh"
            )
            .replacingOccurrences(
                of: #"/Users/ahmed/Documents/Codex/opensteamer"#,
                with: #"/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3"#
            )

        XCTAssertEqual(v8, expected)
        XCTAssertTrue(v8.contains(#"${output_root:t}" == "production-driver-v8""#))
        XCTAssertTrue(v8.contains("schema=opensteamer.production-driver-candidate.v8"))
        XCTAssertTrue(v8.contains("OpensteamerVirtualMicrophone-v8.pkg"))
        XCTAssertTrue(v8.contains("verify-production-driver-package-v8.sh"))
        XCTAssertTrue(v8.contains("parse-installer-signature-v8.sh"))
        XCTAssertTrue(v8.contains(#"$repo" == "/Users/ahmed/Documents/Codex/opensteamer-diagnostic-v3""#))
        XCTAssertTrue(v8.contains("notarytool submit"))
        XCTAssertTrue(v8.contains("stapler staple"))
        XCTAssertFalse(v8.contains("production-driver-v7"))
        XCTAssertFalse(v8.contains("OpensteamerVirtualMicrophone-v7.pkg"))
        XCTAssertFalse(v8.contains("production-driver-candidate.v7"))
        XCTAssertEqual(
            try executableMode(
                "macOS/VirtualAudioDriver/scripts/prepare-production-driver-candidate-v8.sh"
            ),
            0o755
        )
    }

    func testV8ProductionVerifierIsExactVersionedV7Derivation() throws {
        let v7 = try source(
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v7.sh"
        )
        let v8 = try source(
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v8.sh"
        )
        let expected = v7
            .replacingOccurrences(
                of: "OpensteamerVirtualMicrophone-v7",
                with: "OpensteamerVirtualMicrophone-v8"
            )
            .replacingOccurrences(of: "lstat_manifest_v7", with: "lstat_manifest_v8")
            .replacingOccurrences(of: "lstat-manifest-v7", with: "lstat-manifest-v8")
            .replacingOccurrences(
                of: "opensteamer-v7-pkg-signature",
                with: "opensteamer-v8-pkg-signature"
            )
            .replacingOccurrences(
                of: "VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V7",
                with: "VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V8"
            )
            .replacingOccurrences(
                of: "parse-installer-signature-v7.sh",
                with: "parse-installer-signature-v8.sh"
            )

        XCTAssertEqual(v8, expected)
        XCTAssertTrue(v8.contains("OpensteamerVirtualMicrophone-v8.pkg"))
        XCTAssertTrue(v8.contains("--self-test-lstat-manifest-v8"))
        XCTAssertTrue(v8.contains("parse-installer-signature-v8.sh"))
        XCTAssertTrue(v8.contains("VERIFIED_DEVELOPER_ID_NOTARIZED_STAPLED_DRIVER_PACKAGE_V8"))
        XCTAssertFalse(v8.contains("OpensteamerVirtualMicrophone-v7.pkg"))
        XCTAssertFalse(v8.contains("--self-test-lstat-manifest-v7"))
        XCTAssertEqual(
            try executableMode(
                "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v8.sh"
            ),
            0o755
        )
    }

    func testV8InstallerSignatureParserAndMutationTestAreFreshCopies() throws {
        let parserV7 = try source(
            "macOS/VirtualAudioDriver/scripts/parse-installer-signature-v7.sh"
        )
        let parserV8 = try source(
            "macOS/VirtualAudioDriver/scripts/parse-installer-signature-v8.sh"
        )
        let testV7 = try source(
            "macOS/VirtualAudioDriver/scripts/test-installer-signature-parser-v7.sh"
        )
        let testV8 = try source(
            "macOS/VirtualAudioDriver/scripts/test-installer-signature-parser-v8.sh"
        )
        let expectedTest = testV7
            .replacingOccurrences(
                of: "parse-installer-signature-v7.sh",
                with: "parse-installer-signature-v8.sh"
            )
            .replacingOccurrences(
                of: "opensteamer-installer-parser-v7",
                with: "opensteamer-installer-parser-v8"
            )

        XCTAssertEqual(parserV8, parserV7)
        XCTAssertEqual(testV8, expectedTest)
        XCTAssertTrue(testV8.contains("parse-installer-signature-v8.sh"))
        XCTAssertFalse(testV8.contains("parse-installer-signature-v7.sh"))
        XCTAssertEqual(
            try executableMode(
                "macOS/VirtualAudioDriver/scripts/parse-installer-signature-v8.sh"
            ),
            0o755
        )
        XCTAssertEqual(
            try executableMode(
                "macOS/VirtualAudioDriver/scripts/test-installer-signature-parser-v8.sh"
            ),
            0o755
        )
    }

    func testV8OfflineSelfTestsPassWithoutNotarization() throws {
        let publication = try runScript(
            "macOS/VirtualAudioDriver/scripts/prepare-production-driver-candidate-v8.sh",
            arguments: ["--self-test-candidate-publication-v8"]
        )
        XCTAssertEqual(publication.status, 0, publication.stderr)
        XCTAssertTrue(publication.stdout.contains("PASS atomic no-clobber candidate publication"))
        XCTAssertEqual(publication.stderr, "")

        let manifest = try runScript(
            "macOS/VirtualAudioDriver/scripts/verify-production-driver-package-v8.sh",
            arguments: ["--self-test-lstat-manifest-v8"]
        )
        XCTAssertEqual(manifest.status, 0, manifest.stderr)
        XCTAssertEqual(manifest.stdout, "SELF_TEST_OK production-driver-lstat-manifest-v8\n")
        XCTAssertEqual(manifest.stderr, "")

        let parser = try runScript(
            "macOS/VirtualAudioDriver/scripts/test-installer-signature-parser-v8.sh",
            arguments: []
        )
        XCTAssertEqual(parser.status, 0, parser.stderr)
        XCTAssertEqual(parser.stdout, "PASS installer leaf SHA-256 parser rejected 9 mutants\n")
        XCTAssertEqual(parser.stderr, "")
    }
}
