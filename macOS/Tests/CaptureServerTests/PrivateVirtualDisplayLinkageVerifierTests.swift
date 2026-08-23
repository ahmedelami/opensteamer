import Foundation
import XCTest

final class PrivateVirtualDisplayLinkageVerifierTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDynamicLookupPassesAndDirectClassReferenceFails() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opensteamer-private-linkage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let dynamicObject = try compileObject(
            source: """
                #import <Foundation/Foundation.h>
                Class OpensteamerResolveVirtualDisplay(void) {
                    return NSClassFromString(@"CGVirtualDisplay");
                }
                """,
            name: "dynamic",
            in: temporaryDirectory
        )
        let directObject = try compileObject(
            source: """
                #import <Foundation/Foundation.h>
                @interface CGVirtualDisplay : NSObject
                @end
                id OpensteamerConstructVirtualDisplay(void) {
                    return [CGVirtualDisplay new];
                }
                """,
            name: "direct",
            in: temporaryDirectory
        )
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-no-private-virtual-display-imports.sh"
        )

        let accepted = try run(verifier, arguments: [dynamicObject.path])
        XCTAssertEqual(accepted.status, 0, accepted.standardError)
        let rejected = try run(verifier, arguments: [directObject.path])
        XCTAssertNotEqual(rejected.status, 0, rejected.standardOutput)
        XCTAssertTrue(
            rejected.standardError.contains("loader-time dependency"),
            rejected.standardError
        )
    }

    private func compileObject(source: String, name: String, in directory: URL) throws -> URL {
        let sourceURL = directory.appendingPathComponent("\(name).m")
        let objectURL = directory.appendingPathComponent("\(name).o")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                "-fobjc-arc",
                "-fmodules",
                "-c",
                sourceURL.path,
                "-o",
                objectURL.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        return objectURL
    }

    private func run(_ executable: URL, arguments: [String]) throws -> ProcessResult {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}
