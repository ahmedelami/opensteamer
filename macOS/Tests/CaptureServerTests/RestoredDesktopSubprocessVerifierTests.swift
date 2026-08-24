import Foundation
import VirtualDisplayCore
import XCTest
@testable import CaptureServer

final class RestoredDesktopSubprocessVerifierTests: XCTestCase {
    func testProbeRequestRoundTripsExactExpectation() throws {
        let expectation = try makeExpectation()
        let arguments = ["CaptureServer"]
            + RestoredDesktopProbeRequest.arguments(for: expectation)

        XCTAssertEqual(
            RestoredDesktopProbeRequest.parse(arguments),
            .request(expectation)
        )
    }

    func testProbeRequestRejectsMalformedOrMixedArguments() {
        let malformedRequests = [
            ["CaptureServer", RestoredDesktopProbeRequest.flag],
            [
                "CaptureServer", RestoredDesktopProbeRequest.flag,
                "28531", "5912", "1", "1080", "1920", "1080", "0",
            ],
            [
                "CaptureServer", "--verbose", RestoredDesktopProbeRequest.flag,
                "28531", "5912", "1", "1080", "1920", "1080", "1920",
            ],
            [
                "CaptureServer", RestoredDesktopProbeRequest.flag,
                "not-a-number", "5912", "1", "1080", "1920", "1080", "1920",
            ],
        ]

        for arguments in malformedRequests {
            XCTAssertEqual(
                RestoredDesktopProbeRequest.parse(arguments),
                .malformed
            )
        }
        XCTAssertEqual(
            RestoredDesktopProbeRequest.parse(["CaptureServer", "--verbose"]),
            .notRequested
        )
    }

    func testProbeModeMapsProofAndMalformedRequestsToStableStatuses() throws {
        let expectation = try makeExpectation()
        let arguments = ["CaptureServer"]
            + RestoredDesktopProbeRequest.arguments(for: expectation)

        XCTAssertEqual(
            RestoredDesktopProbeMode.exitStatusIfRequested(arguments) { _ in true },
            0
        )
        XCTAssertEqual(
            RestoredDesktopProbeMode.exitStatusIfRequested(arguments) { _ in false },
            RestoredDesktopProbeMode.restorationUnconfirmedExitStatus
        )
        XCTAssertEqual(
            RestoredDesktopProbeMode.exitStatusIfRequested([
                "CaptureServer", RestoredDesktopProbeRequest.flag,
            ]),
            RestoredDesktopProbeMode.malformedRequestExitStatus
        )
        XCTAssertNil(
            RestoredDesktopProbeMode.exitStatusIfRequested([
                "CaptureServer", "--verbose",
            ])
        )
    }

    func testSubprocessVerifierUsesExactExecutableArgumentsAndTimeout() throws {
        let expectation = try makeExpectation()
        let executable = URL(fileURLWithPath: "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer")
        var observedExecutable: URL?
        var observedArguments: [String] = []
        var observedTimeout: TimeInterval = 0
        let verifier = RestoredDesktopSubprocessVerifier(
            executableURL: executable,
            runner: { executableURL, arguments, timeout in
                observedExecutable = executableURL
                observedArguments = arguments
                observedTimeout = timeout
                return true
            }
        )

        XCTAssertTrue(verifier.verify(expectation))
        XCTAssertEqual(observedExecutable, executable)
        XCTAssertEqual(
            observedArguments,
            RestoredDesktopProbeRequest.arguments(for: expectation)
        )
        XCTAssertEqual(observedTimeout, RestoredDesktopSubprocessVerifier.timeout)
    }

    func testSubprocessVerifierFailsClosedWhenRunnerDoesNotConfirm() throws {
        let verifier = RestoredDesktopSubprocessVerifier(
            executableURL: URL(fileURLWithPath: "/tmp/CaptureServer"),
            runner: { _, _, _ in false }
        )

        XCTAssertFalse(verifier.verify(try makeExpectation()))
    }

    private func makeExpectation() throws -> RestoredDesktopExpectation {
        try XCTUnwrap(
            RestoredDesktopExpectation(
                retiredVendorID: 0x6F73,
                retiredProductID: 0x1718,
                retiredSerialNumber: 1,
                logicalWidth: 1_080,
                logicalHeight: 1_920,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            )
        )
    }
}
