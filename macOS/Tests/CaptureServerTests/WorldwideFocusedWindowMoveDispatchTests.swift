import CaptureCore
import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

final class WorldwideFocusedWindowMoveDispatchTests: XCTestCase {
    func testMoveCapabilityAndDispatcherUseSeparateExactAuthority() throws {
        let session = UUID()
        let generation = UUID()
        let actions: [WebRTCInputAction] = [
            .requestFocusedWindowMoveTarget, .selectWindowForMove(at: .init(x: 0.1, y: 0.2)),
            .commitFocusedWindowMove(targetGeneration: generation, start: .init(x: 0.2, y: 0.3), end: .init(x: 0.4, y: 0.5))
        ]
        let old = WebRTCInputCapability(inputSessionID: session, screenRequestID: 3, supportsFocusedWindowResize: true)
        let moveOnly = WebRTCInputCapability(
            inputSessionID: session,
            screenRequestID: 3,
            supportsFocusedWindowMove: true
        )
        let current = WorldwideScreenService.remoteInputCapability(inputSessionID: session, screenRequestID: 3)
        XCTAssertFalse(old.supportsFocusedWindowMoveScaleRebinding)
        XCTAssertTrue(current.supportsFocusedWindowMoveScaleRebinding)
        XCTAssertFalse(old.supportsFocusedWindowMoveRecoverableOffscreen)
        XCTAssertTrue(current.supportsFocusedWindowMoveRecoverableOffscreen)
        let spy = WindowMoveDispatchSpy()
        for (index, action) in actions.enumerated() {
            XCTAssertFalse(WorldwideScreenService.remoteInputActionIsSupported(action, capability: old))
            XCTAssertTrue(WorldwideScreenService.remoteInputActionIsSupported(action, capability: current))
            let request = WebRTCInputRequest(id: UInt64(index + 1), screenRequestID: 3, inputSessionID: session,
                action: action, viewerVideoSize: .init(width: 1920, height: 1080))
            let outcome = try XCTUnwrap(WorldwideFocusedWindowMoveDispatcher.dispatch(request, to: spy))
            XCTAssertTrue(outcome.isWindowMove)
            XCTAssertEqual(outcome.result, .rejected(.windowUnavailable))
            XCTAssertEqual(spy.action, action)
            XCTAssertEqual(spy.screenID, 3)
            XCTAssertEqual(spy.sessionID, session)
            XCTAssertEqual(spy.viewerSize, .init(width: 1920, height: 1080))
        }
        XCTAssertNil(WorldwideFocusedWindowMoveDispatcher.dispatch(
            .init(id: 4, screenRequestID: 3, inputSessionID: session, action: .requestFocusedWindowResizeTarget,
                  viewerVideoSize: .init(width: 1920, height: 1080)), to: spy
        ))

        let offscreen = WebRTCInputAction.commitFocusedWindowMove(
            targetGeneration: generation,
            start: .init(x: 0.2, y: 0.3),
            end: .init(x: 0.4, y: 0.5),
            allowsRecoverableOffscreen: true
        )
        XCTAssertFalse(WorldwideScreenService.remoteInputActionIsSupported(
            offscreen,
            capability: moveOnly
        ))
        XCTAssertTrue(WorldwideScreenService.remoteInputActionIsSupported(
            offscreen,
            capability: current
        ))
        let outcome = try XCTUnwrap(WorldwideFocusedWindowMoveDispatcher.dispatch(
            .init(
                id: 5,
                screenRequestID: 3,
                inputSessionID: session,
                action: offscreen,
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            to: spy
        ))
        XCTAssertTrue(outcome.isWindowMove)
        XCTAssertEqual(spy.action, offscreen)
    }
}

private final class WindowMoveDispatchSpy: WorldwideFocusedWindowMoveDispatching, @unchecked Sendable {
    var action: WebRTCInputAction?
    var screenID: UInt64?
    var sessionID: UUID?
    var viewerSize: MacRemoteInputVideoSize?

    private func record(
        _ action: WebRTCInputAction, _ screen: UInt64, _ session: UUID, _ size: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        self.action = action
        screenID = screen
        sessionID = session
        viewerSize = size
        return .init(result: .rejected(.windowUnavailable))
    }

    func requestFocusedWindowMoveTarget(screenRequestID: UInt64, inputSessionID: UUID, viewerVideoSize: MacRemoteInputVideoSize?) -> MacRemoteWindowResizeDiagnosedResult {
        record(.requestFocusedWindowMoveTarget, screenRequestID, inputSessionID, viewerVideoSize)
    }

    func selectWindowForMove(screenRequestID: UInt64, inputSessionID: UUID, normalizedPoint: MacRemoteNormalizedPoint, viewerVideoSize: MacRemoteInputVideoSize?) -> MacRemoteWindowResizeDiagnosedResult {
        record(.selectWindowForMove(at: .init(x: normalizedPoint.x, y: normalizedPoint.y)), screenRequestID, inputSessionID, viewerVideoSize)
    }

    func commitFocusedWindowMove(screenRequestID: UInt64, inputSessionID: UUID, targetGeneration: UUID, start: MacRemoteNormalizedPoint, end: MacRemoteNormalizedPoint, viewerVideoSize: MacRemoteInputVideoSize?, allowsRecoverableOffscreen: Bool) -> MacRemoteWindowResizeDiagnosedResult {
        record(.commitFocusedWindowMove(targetGeneration: targetGeneration, start: .init(x: start.x, y: start.y), end: .init(x: end.x, y: end.y), allowsRecoverableOffscreen: allowsRecoverableOffscreen), screenRequestID, inputSessionID, viewerVideoSize)
    }
}
