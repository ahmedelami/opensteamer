import CaptureCore
import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

/// Proves focused-window resize remains behind its own capability and the existing revocable
/// input/capture/forwarding transaction. Source assertions are intentionally content-free.
final class WorldwideFocusedWindowResizeDispatchTests: XCTestCase {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testArmedHostAdvertisesResizeButLegacyCapabilityRejectsEveryResizeAction() {
        let legacy = WebRTCInputCapability(inputSessionID: sessionID, screenRequestID: 73)
        let current = WorldwideScreenService.remoteInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 73
        )
        let target = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let actions: [WebRTCInputAction] = [
            .requestFocusedWindowResizeTarget,
            .selectWindowForResize(at: .init(x: 0.4, y: 0.6)),
            .commitFocusedWindowResize(
                targetGeneration: target,
                start: .init(x: 0.4, y: 0.4),
                end: .init(x: 0.3, y: 0.3)
            )
        ]

        XCTAssertFalse(legacy.supportsFocusedWindowResize)
        XCTAssertTrue(current.supportsFocusedWindowResize)
        for action in actions {
            XCTAssertFalse(
                WorldwideScreenService.remoteInputActionIsSupported(
                    action,
                    capability: legacy
                )
            )
            XCTAssertTrue(
                WorldwideScreenService.remoteInputActionIsSupported(
                    action,
                    capability: current
                )
            )
        }
    }

    func testResizeDiagnosticNamesContainNoCoordinatesOrOpaqueGeneration() {
        let actionsAndNames: [(WebRTCInputAction, String)] = [
            (.requestFocusedWindowResizeTarget, "focused-window-target"),
            (.selectWindowForResize(at: .init(x: 0.123, y: 0.987)), "focused-window-selection"),
            (
                .commitFocusedWindowResize(
                    targetGeneration: UUID(),
                    start: .init(x: 0.2, y: 0.3),
                    end: .init(x: 0.8, y: 0.7)
                ),
                "focused-window-resize-commit"
            )
        ]

        for (action, expected) in actionsAndNames {
            XCTAssertEqual(WorldwideScreenService.remoteInputDiagnosticName(for: action), expected)
        }
    }

    func testResizeDispatchBehaviorallyForwardsExactStageAuthorityAndViewerGeometry() throws {
        let targetGeneration = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let controller = FocusedWindowResizeDispatchSpy()
        let requests = [
            WebRTCInputRequest(
                id: 1,
                screenRequestID: 73,
                inputSessionID: sessionID,
                action: .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            WebRTCInputRequest(
                id: 2,
                screenRequestID: 73,
                inputSessionID: sessionID,
                action: .selectWindowForResize(at: .init(x: 0.4, y: 0.6)),
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            ),
            WebRTCInputRequest(
                id: 3,
                screenRequestID: 73,
                inputSessionID: sessionID,
                action: .commitFocusedWindowResize(
                    targetGeneration: targetGeneration,
                    start: .init(x: 0.2, y: 0.3),
                    end: .init(x: 0.8, y: 0.7)
                ),
                viewerVideoSize: .init(width: 750, height: 1_334)
            )
        ]

        let outcomes = try requests.map {
            try XCTUnwrap(
                WorldwideFocusedWindowResizeDispatcher.dispatch($0, to: controller)
            )
        }

        XCTAssertEqual(
            outcomes.map(\.result),
            [
                .accepted(.none),
                .rejected(.windowUnavailable),
                .rejected(.windowResizeFailed)
            ]
        )
        XCTAssertEqual(
            controller.calls,
            [
                .targetRequest(
                    screenRequestID: 73,
                    inputSessionID: sessionID,
                    viewerVideoSize: .init(width: 1_920, height: 1_080)
                ),
                .selection(
                    screenRequestID: 73,
                    inputSessionID: sessionID,
                    point: .init(x: 0.4, y: 0.6),
                    viewerVideoSize: .init(width: 1_080, height: 2_340)
                ),
                .commit(
                    screenRequestID: 73,
                    inputSessionID: sessionID,
                    targetGeneration: targetGeneration,
                    start: .init(x: 0.2, y: 0.3),
                    end: .init(x: 0.8, y: 0.7),
                    viewerVideoSize: .init(width: 750, height: 1_334)
                )
            ]
        )
        XCTAssertNil(
            WorldwideFocusedWindowResizeDispatcher.dispatch(
                .init(
                    id: 4,
                    screenRequestID: 73,
                    inputSessionID: sessionID,
                    action: .tap(.init(x: 0.5, y: 0.5))
                ),
                to: controller
            )
        )
        XCTAssertEqual(controller.calls.count, 3)
    }

    func testDelayedFeedbackFailureIsFencedFromANewerPeerAndInputSession() throws {
        let handler = try serviceSlice(
            after: "    private func handleRemoteInputRequest(",
            before: "    /// Holds input, capture, then the exact forwarding authorization"
        )
        let sourcePeer = try XCTUnwrap(handler.range(of: "let sourcePeer = peer"))
        let send = try XCTUnwrap(handler.range(of: "try await sourcePeer.sendInputFeedback("))
        let peerFence = try XCTUnwrap(
            handler.range(of: "peer === sourcePeer", range: send.upperBound..<handler.endIndex)
        )
        let generationFence = try XCTUnwrap(
            handler.range(
                of: "peerGeneration == sourcePeerGeneration",
                range: peerFence.upperBound..<handler.endIndex
            )
        )
        let authorizationFence = try XCTUnwrap(
            handler.range(
                of: "activeInputAuthorization === authorization",
                range: generationFence.upperBound..<handler.endIndex
            )
        )
        let revocation = try XCTUnwrap(
            handler.range(
                of: "revokeRemoteInputAuthorization()",
                range: authorizationFence.upperBound..<handler.endIndex
            )
        )

        XCTAssertLessThan(sourcePeer.lowerBound, send.lowerBound)
        XCTAssertLessThan(send.lowerBound, peerFence.lowerBound)
        XCTAssertLessThan(peerFence.lowerBound, generationFence.lowerBound)
        XCTAssertLessThan(generationFence.lowerBound, authorizationFence.lowerBound)
        XCTAssertLessThan(authorizationFence.lowerBound, revocation.lowerBound)
    }

    func testUncertainRestorationRevokesAndCommitFeedbackEchoesConsumedAuthority() throws {
        let feedback = try serviceSlice(
            after: "    private func transportFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        let uncertain = try XCTUnwrap(feedback.range(of: "case .windowResizeUncertain:"))
        let revokes = try XCTUnwrap(
            feedback.range(of: "revokesSession = true", range: uncertain.upperBound..<feedback.endIndex)
        )
        XCTAssertLessThan(uncertain.lowerBound, revokes.lowerBound)

        let conversion = try serviceSlice(
            after: "    private func wireWindowResizeFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        XCTAssertTrue(
            conversion.contains(
                "committedTargetGeneration: feedback.committedTargetGeneration"
            )
        )
    }

    private func serviceSlice(after startMarker: String, before endMarker: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}

private final class FocusedWindowResizeDispatchSpy:
    WorldwideFocusedWindowResizeDispatching,
    @unchecked Sendable
{
    enum Call: Equatable {
        case targetRequest(
            screenRequestID: UInt64,
            inputSessionID: UUID,
            viewerVideoSize: MacRemoteInputVideoSize?
        )
        case selection(
            screenRequestID: UInt64,
            inputSessionID: UUID,
            point: MacRemoteNormalizedPoint,
            viewerVideoSize: MacRemoteInputVideoSize?
        )
        case commit(
            screenRequestID: UInt64,
            inputSessionID: UUID,
            targetGeneration: UUID,
            start: MacRemoteNormalizedPoint,
            end: MacRemoteNormalizedPoint,
            viewerVideoSize: MacRemoteInputVideoSize?
        )
    }

    private(set) var calls: [Call] = []

    func requestFocusedWindowResizeTarget(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        calls.append(
            .targetRequest(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                viewerVideoSize: viewerVideoSize
            )
        )
        return .init(result: .accepted(.none))
    }

    func selectWindowForResize(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        calls.append(
            .selection(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                point: normalizedPoint,
                viewerVideoSize: viewerVideoSize
            )
        )
        return .init(result: .rejected(.windowUnavailable))
    }

    func commitFocusedWindowResize(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        targetGeneration: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        calls.append(
            .commit(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                targetGeneration: targetGeneration,
                start: start,
                end: end,
                viewerVideoSize: viewerVideoSize
            )
        )
        return .init(result: .rejected(.windowResizeFailed))
    }
}
