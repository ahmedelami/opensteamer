import Foundation
import XCTest
@testable import WebRTCTransport

final class WebRTCWindowMoveProtocolTests: XCTestCase {
    private let session = UUID()
    private let generation = UUID()
    private var actions: [WebRTCInputAction] {
        [.requestFocusedWindowMoveTarget, .selectWindowForMove(at: .init(x: 0.3, y: 0.4)),
         .commitFocusedWindowMove(targetGeneration: generation, start: .init(x: 0.1, y: 0.8), end: .init(x: 0.7, y: 0.2))]
    }

    func testMoveCapabilitiesAreAdditiveAndStrict() throws {
        let current = WebRTCInputCapability(
            inputSessionID: session,
            screenRequestID: 1,
            supportsFocusedWindowMove: true,
            supportsFocusedWindowMoveScaleRebinding: true,
            supportsFocusedWindowMoveRecoverableOffscreen: true
        )
        let data = try JSONEncoder().encode(current)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputCapability.self, from: data), current)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (keyPath, key) in [
            (\WebRTCInputCapability.supportsFocusedWindowMove, "supportsFocusedWindowMove"),
            (\WebRTCInputCapability.supportsFocusedWindowMoveScaleRebinding, "supportsFocusedWindowMoveScaleRebinding"),
            (\WebRTCInputCapability.supportsFocusedWindowMoveRecoverableOffscreen, "supportsFocusedWindowMoveRecoverableOffscreen")
        ] {
            var legacyObject = object
            legacyObject.removeValue(forKey: key)
            let legacy = try JSONDecoder().decode(
                WebRTCInputCapability.self,
                from: JSONSerialization.data(withJSONObject: legacyObject)
            )
            XCTAssertFalse(legacy[keyPath: keyPath])
            for invalid in [NSNull(), 1, "true"] as [Any] {
                var invalidObject = object
                invalidObject[key] = invalid
                XCTAssertThrowsError(try JSONDecoder().decode(
                    WebRTCInputCapability.self,
                    from: JSONSerialization.data(withJSONObject: invalidObject)
                ))
            }
        }
    }

    func testEveryMoveActionRequiresViewerGeometryAndRoundTrips() throws {
        for action in actions {
            let request = WebRTCInputRequest(id: 1, screenRequestID: 1, inputSessionID: session,
                action: action, viewerVideoSize: .init(width: 1920, height: 1080))
            let data = try JSONEncoder().encode(request)
            XCTAssertLessThan(data.count, WebRTCInputCapability.maximumMessageBytes)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputRequest.self, from: data), request)
            XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputRequest(
                id: 1, screenRequestID: 1, inputSessionID: session, action: action
            )))
        }
        for raw in [
            #"{"kind":"focusedWindowMoveTarget","point":{"x":0.1,"y":0.2}}"#,
            #"{"kind":"focusedWindowMoveSelection","point":{"x":1.1,"y":0.2}}"#,
            #"{"kind":"focusedWindowMoveCommit","targetGeneration":"00000000-0000-0000-0000-000000000000","start":{"x":0.1,"y":0.2},"end":{"x":0.3,"y":0.4}}"#,
            #"{"kind":"focusedWindowMoveCommit","start":{"x":0.1,"y":0.2},"end":{"x":0.3,"y":0.4}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: Data(raw.utf8)))
        }
    }

    func testMoveOffscreenOptInIsAdditiveStrictAndAbsentForLegacyCommit() throws {
        let legacy = WebRTCInputAction.commitFocusedWindowMove(
            targetGeneration: generation,
            start: .init(x: 0.1, y: 0.8),
            end: .init(x: 0.7, y: 0.2)
        )
        let current = WebRTCInputAction.commitFocusedWindowMove(
            targetGeneration: generation,
            start: .init(x: 0.1, y: 0.8),
            end: .init(x: 0.7, y: 0.2),
            allowsRecoverableOffscreen: true
        )
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        XCTAssertNil(legacyObject["allowsRecoverableOffscreen"])
        let currentData = try JSONEncoder().encode(current)
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        XCTAssertEqual(currentObject["allowsRecoverableOffscreen"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: currentData), current)

        var invalid = currentObject
        invalid["allowsRecoverableOffscreen"] = "true"
        XCTAssertThrowsError(try JSONDecoder().decode(
            WebRTCInputAction.self,
            from: JSONSerialization.data(withJSONObject: invalid)
        ))
        invalid = currentObject
        invalid["kind"] = "focusedWindowResizeCommit"
        XCTAssertThrowsError(try JSONDecoder().decode(
            WebRTCInputAction.self,
            from: JSONSerialization.data(withJSONObject: invalid)
        ))
    }

    func testMoveOffscreenOptInIsRejectedByEveryOtherActionShape() throws {
        let otherActions: [WebRTCInputAction] = [
            .tap(.init(x: 0.1, y: 0.2)),
            .primaryDrag(start: .init(x: 0.1, y: 0.2), end: .init(x: 0.3, y: 0.4)),
            .scroll(anchor: .init(x: 0.1, y: 0.2), deltaX: 1, deltaY: -1),
            .requestFocusedWindowResizeTarget,
            .selectWindowForResize(at: .init(x: 0.1, y: 0.2)),
            .commitFocusedWindowResize(
                targetGeneration: generation,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.3, y: 0.4)
            ),
            .requestFocusedWindowMoveTarget,
            .selectWindowForMove(at: .init(x: 0.1, y: 0.2)),
            .insertText("x", focusGeneration: 1),
            .backspace(focusGeneration: 1),
            .returnKey(focusGeneration: 1),
        ]

        for action in otherActions {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(action))
                    as? [String: Any]
            )
            object["allowsRecoverableOffscreen"] = true
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WebRTCInputAction.self,
                    from: JSONSerialization.data(withJSONObject: object)
                ),
                "Unexpected offscreen opt-in must reject \(action)"
            )
        }
    }

    func testMoveTargetKeepsLegacyVisibleIntersectionAndValidatesOptionalFullFrame() throws {
        let visible = WebRTCNormalizedRect(x: 0, y: 0.2, width: 0.2, height: 0.5)
        let legacyJSON = """
        {"generation":"\(generation.uuidString)","normalizedFrame":{"x":0,"y":0.2,"width":0.2,"height":0.5}}
        """
        let legacy = try JSONDecoder().decode(
            WebRTCWindowMoveTarget.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(legacy.normalizedFrame, visible)
        XCTAssertNil(legacy.unclippedNormalizedFrame)

        let full = WebRTCWindowMoveUnclippedNormalizedRect(
            x: -0.3,
            y: 0.2,
            width: 0.5,
            height: 0.5
        )
        let current = WebRTCWindowMoveTarget(
            generation: generation,
            normalizedFrame: visible,
            unclippedNormalizedFrame: full
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCWindowMoveTarget.self,
                from: JSONEncoder().encode(current)
            ),
            current
        )

        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCWindowMoveTarget(
            generation: UUID(),
            normalizedFrame: .init(x: 0.8, y: 0.2, width: 0.2, height: 0.5),
            unclippedNormalizedFrame: full
        )))
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCWindowMoveTarget(
            generation: UUID(),
            normalizedFrame: visible,
            unclippedNormalizedFrame: .init(x: -Double.infinity, y: 0, width: 1, height: 1)
        )))
    }

    func testFeedbackBindsExactMoveStageAndConsumedGeneration() throws {
        let target = WebRTCWindowMoveTarget(generation: UUID(), normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let kinds: [WebRTCWindowMoveFeedbackKind] = [.targetAcquired, .windowSelected, .moveCommitted]
        for (index, action) in actions.enumerated() {
            let move = WebRTCWindowMoveFeedback(kind: kinds[index],
                committedTargetGeneration: index == 2 ? generation : nil, target: target)
            let feedback = WebRTCInputFeedback(id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted, windowMove: move)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputFeedback.self, from: JSONEncoder().encode(feedback)), feedback)
            for (otherIndex, other) in actions.enumerated() {
                XCTAssertEqual(WebRTCInputRequestActionBinding(other).permits(feedback), index == otherIndex)
            }
            XCTAssertFalse(WebRTCInputRequestActionBinding(.requestFocusedWindowResizeTarget).permits(feedback))
            XCTAssertFalse(WebRTCInputRequestActionBinding(.tap(.init(x: 0.1, y: 0.1))).permits(feedback))
            XCTAssertTrue(WebRTCInputRequestActionBinding(action).permits(feedback))
        }
        let wrong = WebRTCInputFeedback(id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted,
            windowMove: .init(kind: .moveCommitted, committedTargetGeneration: UUID(), target: target))
        XCTAssertFalse(WebRTCInputRequestActionBinding(actions[2]).permits(wrong))
    }

    func testFeedbackRejectsMixedAuthorityRejectedTargetsAndReusedSuccessor() throws {
        let target = WebRTCWindowMoveTarget(generation: generation, normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let move = WebRTCWindowMoveFeedback(kind: .targetAcquired, target: target)
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputFeedback(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted,
            windowResize: .init(
                kind: .targetAcquired,
                target: .init(generation: generation, normalizedFrame: target.normalizedFrame)
            ),
            windowMove: move
        )))
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputFeedback(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .rejected,
            rejectionReason: .rateLimited, windowMove: move
        )))
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCWindowMoveFeedback(
            kind: .moveCommitted, committedTargetGeneration: generation, target: target
        )))
    }

    func testMoveCapabilityIsEnforcedByViewerAndHost() async throws {
        let capability = WebRTCInputCapability(inputSessionID: session, screenRequestID: 1, supportsFocusedWindowResize: true)
        let viewer = try WebRTCPeer(configuration: .init(role: .viewer, iceServers: []))
        let viewerAuthorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(capability: capability, authorization: viewerAuthorization)
        for action in actions {
            do {
                _ = try await viewer.requestInput(action, viewerVideoSize: .init(width: 1920, height: 1080),
                    capability: capability, authorization: viewerAuthorization)
                XCTFail("Move requires its own advertised capability")
            } catch WebRTCTransportError.invalidInputRequest {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await viewer.close(reason: .viewerDisconnected)
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(capability: capability, authorization: authorization)
        let admitted = await host.receiveInputRequestForTesting(.init(
            id: 1, screenRequestID: 1, inputSessionID: session, action: actions[0],
            viewerVideoSize: .init(width: 1920, height: 1080)
        ))
        XCTAssertFalse(admitted)
        XCTAssertFalse(authorization.isValid)
        await host.close(reason: .hostStopped)
    }

    func testRecoverableOffscreenCommitNeedsExactAdvertisedCapability() async throws {
        let moveOnly = WebRTCInputCapability(
            inputSessionID: session,
            screenRequestID: 1,
            supportsFocusedWindowMove: true
        )
        let viewer = try WebRTCPeer(configuration: .init(role: .viewer, iceServers: []))
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: moveOnly,
            authorization: authorization
        )
        let action = WebRTCInputAction.commitFocusedWindowMove(
            targetGeneration: generation,
            start: .init(x: 0.2, y: 0.2),
            end: .init(x: 0.8, y: 0.8),
            allowsRecoverableOffscreen: true
        )
        do {
            _ = try await viewer.requestInput(
                action,
                viewerVideoSize: .init(width: 1_920, height: 1_080),
                capability: moveOnly,
                authorization: authorization
            )
            XCTFail("Offscreen opt-in must require its own advertised capability")
        } catch WebRTCTransportError.invalidInputRequest {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await viewer.close(reason: .viewerDisconnected)
    }

    func testMoveCommitReplayRetainsFeedbackAndNeverRepeatsApplicationWork() async throws {
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let capability = WebRTCInputCapability(inputSessionID: session, screenRequestID: 1, supportsFocusedWindowMove: true)
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(capability: capability, authorization: authorization)
        await host.beginRemoteInputControlDataCaptureForTesting()
        let request = WebRTCInputRequest(id: 1, screenRequestID: 1, inputSessionID: session,
            action: actions[2], viewerVideoSize: .init(width: 1920, height: 1080))
        let admitted = await host.receiveInputRequestForTesting(request)
        XCTAssertTrue(admitted)
        let move = WebRTCWindowMoveFeedback(kind: .moveCommitted, committedTargetGeneration: generation,
            target: .init(generation: UUID(), normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5)))
        try await host.sendInputFeedback(for: 1, result: .accepted, windowMove: move)
        let replayed = await host.receiveInputRequestForTesting(request)
        XCTAssertTrue(replayed)
        let snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 1)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 1)
        let expected = ControlChannelMessage.inputFeedback(.init(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted, windowMove: move
        ))
        XCTAssertEqual(try snapshot.capturedControlData.map {
            try JSONDecoder().decode(ControlChannelMessage.self, from: $0)
        }, [expected, expected])
        XCTAssertTrue(authorization.isValid)
        await host.close(reason: .hostStopped)
    }

    func testMoveCommitDuplicateIdentityIncludesRecoverableOffscreenOptIn() async throws {
        for initialOptIn in [false, true] {
            let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
            let capability = WebRTCInputCapability(
                inputSessionID: session,
                screenRequestID: initialOptIn ? 2 : 1,
                supportsFocusedWindowMove: true,
                supportsFocusedWindowMoveRecoverableOffscreen: true
            )
            let authorization = WebRTCInputAuthorization()
            try await host.installHostInputSessionForTesting(
                capability: capability,
                authorization: authorization
            )
            await host.beginRemoteInputControlDataCaptureForTesting()

            func request(
                start: WebRTCNormalizedPoint,
                end: WebRTCNormalizedPoint,
                viewerVideoSize: WebRTCInputVideoSize,
                allowsRecoverableOffscreen: Bool
            ) -> WebRTCInputRequest {
                WebRTCInputRequest(
                    id: 7,
                    screenRequestID: capability.screenRequestID,
                    inputSessionID: capability.inputSessionID,
                    action: .commitFocusedWindowMove(
                        targetGeneration: generation,
                        start: start,
                        end: end,
                        allowsRecoverableOffscreen: allowsRecoverableOffscreen
                    ),
                    viewerVideoSize: viewerVideoSize
                )
            }

            let first = request(
                start: .init(x: 0.1, y: 0.8),
                end: .init(x: 0.7, y: 0.2),
                viewerVideoSize: .init(width: 1_920, height: 1_080),
                allowsRecoverableOffscreen: initialOptIn
            )
            let firstWasAccepted = await host.receiveInputRequestForTesting(first)
            XCTAssertTrue(firstWasAccepted)

            let move = WebRTCWindowMoveFeedback(
                kind: .moveCommitted,
                committedTargetGeneration: generation,
                target: .init(
                    generation: UUID(),
                    normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
                )
            )
            try await host.sendInputFeedback(for: first.id, result: .accepted, windowMove: move)

            let equivalentDuplicate = request(
                start: .init(x: 0.9, y: 0.7),
                end: .init(x: 0.2, y: 0.3),
                viewerVideoSize: .init(width: 750, height: 1_334),
                allowsRecoverableOffscreen: initialOptIn
            )
            let duplicateWasAccepted = await host.receiveInputRequestForTesting(
                equivalentDuplicate
            )
            XCTAssertTrue(duplicateWasAccepted)

            var snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
            XCTAssertEqual(snapshot.receivedRequestHistoryCount, 1)
            XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
            XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 1)
            XCTAssertEqual(snapshot.capturedControlData.count, 2)
            XCTAssertTrue(authorization.isValid)

            let conflictingDuplicate = request(
                start: .init(x: 0.4, y: 0.6),
                end: .init(x: 0.6, y: 0.4),
                viewerVideoSize: .init(width: 1_536, height: 864),
                allowsRecoverableOffscreen: !initialOptIn
            )
            let conflictWasAccepted = await host.receiveInputRequestForTesting(
                conflictingDuplicate
            )
            XCTAssertFalse(conflictWasAccepted)

            snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
            XCTAssertEqual(snapshot.receivedRequestHistoryCount, 0)
            XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
            XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 0)
            XCTAssertEqual(snapshot.capturedControlData.count, 2)
            XCTAssertFalse(authorization.isValid)
            let capabilityAfterConflict = await host.currentInputCapability()
            XCTAssertNil(capabilityAfterConflict)

            await host.close(reason: .hostStopped)
        }
    }
}
