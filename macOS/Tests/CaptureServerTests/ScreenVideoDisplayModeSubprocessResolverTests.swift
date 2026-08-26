import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

final class ScreenVideoDisplayModeSubprocessResolverTests: XCTestCase {
    func testProbeRequestRoundTripsExactDisplayRequirement() {
        let requirement = makeDisplayRequirement()
        let arguments = ["CaptureServer"]
            + ScreenVideoDisplayModeProbeRequest.arguments(
                displayID: 206,
                displayRequirement: requirement
            )

        XCTAssertEqual(
            ScreenVideoDisplayModeProbeRequest.parse(arguments),
            .request(
                ScreenVideoDisplayModeProbeRequest(
                    displayID: 206,
                    displayRequirement: requirement
                )
            )
        )
    }

    func testProbeRequestRoundTripsWithoutDisplayRequirement() {
        let arguments = ["CaptureServer"]
            + ScreenVideoDisplayModeProbeRequest.arguments(
                displayID: 42,
                displayRequirement: nil
            )

        XCTAssertEqual(
            ScreenVideoDisplayModeProbeRequest.parse(arguments),
            .request(
                ScreenVideoDisplayModeProbeRequest(
                    displayID: 42,
                    displayRequirement: nil
                )
            )
        )
    }

    func testProbeRequestRejectsMalformedOrMixedArguments() {
        let flag = ScreenVideoDisplayModeProbeRequest.flag
        let malformedRequests = [
            ["CaptureServer", flag],
            ["CaptureServer", flag, "206", "1", "0", "5912", "1", "1"],
            ["CaptureServer", flag, "206", "0", "28531", "0", "0", "0"],
            ["CaptureServer", flag, "206", "2", "28531", "5912", "1", "1"],
            ["CaptureServer", "--verbose", flag, "206", "1", "28531", "5912", "1", "1"],
        ]

        for arguments in malformedRequests {
            XCTAssertEqual(
                ScreenVideoDisplayModeProbeRequest.parse(arguments),
                .malformed
            )
        }
        XCTAssertEqual(
            ScreenVideoDisplayModeProbeRequest.parse(["CaptureServer", "--verbose"]),
            .notRequested
        )
    }

    func testProbeModeRendersOneExactMachineRecord() {
        let arguments = ["CaptureServer"]
            + ScreenVideoDisplayModeProbeRequest.arguments(
                displayID: 206,
                displayRequirement: makeDisplayRequirement()
            )

        let execution = ScreenVideoDisplayModeProbeMode.executionIfRequested(arguments) { request in
            XCTAssertEqual(request.displayID, 206)
            return makeDisplayModeSnapshot()
        }

        XCTAssertEqual(
            execution,
            ScreenVideoDisplayModeProbeExecution(
                exitStatus: 0,
                output: "opensteamer-display-mode-v1 206 540 1170 1080 2340\n"
            )
        )
    }

    func testProbeModeFailsClosedForMalformedRequestOrUnavailableSnapshot() {
        XCTAssertEqual(
            ScreenVideoDisplayModeProbeMode.executionIfRequested([
                "CaptureServer", ScreenVideoDisplayModeProbeRequest.flag,
            ]),
            ScreenVideoDisplayModeProbeExecution(
                exitStatus: ScreenVideoDisplayModeProbeMode.malformedRequestExitStatus,
                output: nil
            )
        )
        let arguments = ["CaptureServer"]
            + ScreenVideoDisplayModeProbeRequest.arguments(
                displayID: 206,
                displayRequirement: makeDisplayRequirement()
            )
        XCTAssertEqual(
            ScreenVideoDisplayModeProbeMode.executionIfRequested(arguments) { _ in nil },
            ScreenVideoDisplayModeProbeExecution(
                exitStatus: ScreenVideoDisplayModeProbeMode.snapshotUnavailableExitStatus,
                output: nil
            )
        )
    }

    func testProbeOutputParserReturnsOnlyExactRequestedMapping() {
        let valid = "opensteamer-display-mode-v1 206 540 1170 1080 2340\n"
        XCTAssertEqual(
            ScreenVideoDisplayModeProbeMode.parseOutput(valid, expectedDisplayID: 206),
            makeDisplayModeSnapshot()
        )

        let invalidOutputs = [
            "opensteamer-display-mode-v1 204 540 1170 1080 2340\n",
            "opensteamer-display-mode-v1 206 540 1170 unavailable\n",
            "opensteamer-display-mode-v1 206 1 1170 1080 2340\n",
            "opensteamer-display-mode-v1 206 999999999999999999999 1170 1080 2340\n",
            valid + valid,
        ]
        for output in invalidOutputs {
            XCTAssertNil(
                ScreenVideoDisplayModeProbeMode.parseOutput(
                    output,
                    expectedDisplayID: 206
                )
            )
        }
    }

    func testResolverUsesExactFreshProbeArgumentsAndTimeout() async throws {
        let executable = URL(
            fileURLWithPath: "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
        )
        let recorder = ResolverInvocationRecorder(
            output: "opensteamer-display-mode-v1 206 540 1170 1080 2340\n"
        )
        let resolver = ScreenVideoDisplayModeSubprocessResolver(
            executableURL: executable,
            runner: { executableURL, arguments, timeout in
                recorder.record(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        let snapshot = try await resolver.resolve(
            206,
            displayRequirement: makeDisplayRequirement()
        )

        XCTAssertEqual(snapshot, makeDisplayModeSnapshot())
        XCTAssertEqual(recorder.executableURL, executable)
        XCTAssertEqual(
            recorder.arguments,
            ScreenVideoDisplayModeProbeRequest.arguments(
                displayID: 206,
                displayRequirement: makeDisplayRequirement()
            )
        )
        XCTAssertEqual(recorder.timeout, ScreenVideoDisplayModeSubprocessResolver.timeout)
    }

    func testResolverFailsClosedWhenProbeOrOutputDoesNotResolveTarget() async {
        let executable = URL(fileURLWithPath: "/tmp/CaptureServer")
        let failedProbe = ScreenVideoDisplayModeSubprocessResolver(
            executableURL: executable,
            runner: { _, _, _ in nil }
        )
        let malformedProbe = ScreenVideoDisplayModeSubprocessResolver(
            executableURL: executable,
            runner: { _, _, _ in "not-a-mode-snapshot\n" }
        )

        await XCTAssertThrowsErrorAsync(
            try await failedProbe.resolve(206, displayRequirement: nil)
        ) { error in
            XCTAssertEqual(
                error as? ScreenVideoDisplayModeSubprocessResolverError,
                .probeFailed(206)
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await malformedProbe.resolve(206, displayRequirement: nil)
        ) { error in
            XCTAssertEqual(
                error as? ScreenVideoDisplayModeSubprocessResolverError,
                .snapshotUnavailable(206)
            )
        }
    }

    func testBoundedRunnerReturnsOutputAndRejectsNonzeroOversizedOrTimedOutProcess() {
        let success = ScreenVideoDisplayModeSubprocessResolver.runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'mode-snapshot'"],
            timeout: 1
        )
        XCTAssertEqual(success, "mode-snapshot")

        XCTAssertNil(
            ScreenVideoDisplayModeSubprocessResolver.runBoundedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                timeout: 1
            )
        )
        XCTAssertNil(
            ScreenVideoDisplayModeSubprocessResolver.runBoundedProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "i=0; while [ $i -lt 5000 ]; do printf x; i=$((i+1)); done",
                ],
                timeout: 1
            )
        )
        XCTAssertNil(
            ScreenVideoDisplayModeSubprocessResolver.runBoundedProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
        )
    }
}

private final class ResolverInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let output: String?
    private var storedExecutableURL: URL?
    private var storedArguments: [String] = []
    private var storedTimeout: TimeInterval = 0

    init(output: String?) {
        self.output = output
    }

    var executableURL: URL? { lock.withLock { storedExecutableURL } }
    var arguments: [String] { lock.withLock { storedArguments } }
    var timeout: TimeInterval { lock.withLock { storedTimeout } }

    func record(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        lock.withLock {
            storedExecutableURL = executableURL
            storedArguments = arguments
            storedTimeout = timeout
        }
        return output
    }
}

private func makeDisplayRequirement() -> ScreenVideoDisplayRequirement {
    ScreenVideoDisplayRequirement(
        vendorID: 0x6F73,
        productID: 0x1718,
        serialNumber: 1,
        requiresSoleMainDisplay: true
    )
}

private func makeDisplayModeSnapshot() -> ScreenVideoDisplayModeSnapshot {
    ScreenVideoDisplayModeSnapshot(
        logicalDimensions: .init(width: 540, height: 1_170),
        pixelDimensions: .init(width: 1_080, height: 2_340)
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
