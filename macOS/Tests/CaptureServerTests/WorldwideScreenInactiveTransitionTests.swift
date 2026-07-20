import XCTest
@testable import CaptureServer

@MainActor
final class WorldwideScreenInactiveTransitionTests: XCTestCase {
    func testSuccessfulTransitionStopsNativeCaptureBeforeInactiveAcknowledgement() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
    }

    func testThrowingNativeStopRejectsInactiveAcknowledgementAndClosesSession() async {
        let source = ThrowingScreenStopSource()
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
                try await source.stop()
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(source.stopAttemptCount, 1)
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 0)
        XCTAssertEqual(probe.closeSessionCount, 1)
        XCTAssertEqual(probe.events, ["native-stop", "close-session"])
        XCTAssertEqual(probe.closeError as? ThrowingScreenStopSource.StopError, .injected)

        guard case .nativeStop(let error) = failure else {
            return XCTFail("A throwing native stop must remain a visible native-stop failure.")
        }
        XCTAssertEqual(error as? ThrowingScreenStopSource.StopError, .injected)
    }

    func testAcknowledgementFailureOccursAfterNativeStopWithoutClosingSession() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
                throw InactiveAcknowledgementError.injected
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
        guard case .acknowledgement(let error) = failure else {
            return XCTFail("A throwing acknowledgement must remain a visible ACK failure.")
        }
        XCTAssertEqual(error as? InactiveAcknowledgementError, .injected)
    }

    func testHideCommandUsesVerifiedNativeStopBoundaryBeforeInactiveAcknowledgement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        let serviceSource = try String(contentsOf: serviceSourceURL, encoding: .utf8)
        let handler = try sourceSlice(
            in: serviceSource,
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "    @discardableResult\n    private func acknowledgeInactiveAfterVerifiedScreenStop("
        )
        let hideBranch = try sourceSlice(
            in: handler,
            after: "        case .hideScreen:",
            before: "        case .requestKeyFrame:"
        )

        XCTAssertEqual(hideContractViolations(in: hideBranch), [])

        let directAcknowledgementMutant = hideBranch.replacingOccurrences(
            of: "acknowledgeInactiveAfterVerifiedScreenStop(",
            with: "peer.acknowledgeControlRequest("
        )
        XCTAssertNotEqual(directAcknowledgementMutant, hideBranch)
        XCTAssertEqual(
            Set(hideContractViolations(in: directAcknowledgementMutant)),
            Set([
                "verified-boundary-call-count",
                "direct-peer-acknowledgement",
            ]),
            "The source oracle itself must reject a regression that bypasses the boundary."
        )

        let verifiedBoundary = try sourceSlice(
            in: serviceSource,
            after: "    private func acknowledgeInactiveAfterVerifiedScreenStop(",
            before: "    @discardableResult\n    private func stopScreenCaptureOrCloseSession("
        )
        XCTAssertTrue(
            verifiedBoundary.contains("WorldwideScreenInactiveTransition.perform("),
            "The production helper must use the behavior-tested transition boundary."
        )
        let nativeStop = try XCTUnwrap(
            verifiedBoundary.range(of: "try await self.stopScreenCapture()")
        )
        let inactiveAcknowledgement = try XCTUnwrap(
            verifiedBoundary.range(
                of: "try await peer.acknowledgeControlRequest(\n                    id: requestID,\n                    state: .inactive"
            )
        )
        XCTAssertLessThan(
            nativeStop.lowerBound,
            inactiveAcknowledgement.lowerBound,
            "The production boundary must attempt native stop before sending Inactive."
        )
    }

    private func sourceSlice(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }

    private func hideContractViolations(in hideBranch: String) -> [String] {
        var violations: [String] = []
        let verifiedCallCount = hideBranch.components(
            separatedBy: "acknowledgeInactiveAfterVerifiedScreenStop("
        ).count - 1
        if verifiedCallCount != 1 {
            violations.append("verified-boundary-call-count")
        }
        if !hideBranch.contains("peer: peer,") {
            violations.append("peer-argument")
        }
        if !hideBranch.contains("requestID: request.id,") {
            violations.append("request-id-argument")
        }
        if !hideBranch.contains("context: \"screen Hide\"") {
            violations.append("hide-context")
        }
        if hideBranch.contains("peer.acknowledgeControlRequest(") {
            violations.append("direct-peer-acknowledgement")
        }
        return violations
    }
}

private enum InactiveAcknowledgementError: Error, Equatable {
    case injected
}

@MainActor
private final class ThrowingScreenStopSource {
    enum StopError: Error, Equatable {
        case injected
    }

    private(set) var stopAttemptCount = 0

    func stop() async throws {
        stopAttemptCount += 1
        throw StopError.injected
    }
}

@MainActor
private final class InactiveTransitionProbe {
    var events: [String] = []
    var inactiveAcknowledgementCount = 0
    var closeSessionCount = 0
    var closeError: (any Error)?
}
