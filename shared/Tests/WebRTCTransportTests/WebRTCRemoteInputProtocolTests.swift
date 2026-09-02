import Foundation
import Dispatch
@testable import WebRTCTransport
import XCTest

/// Proves strict remote-input wire shapes, capability and focus binding, secret-text non-retention,
/// and synchronous authorization revocation at native and actor boundaries.
final class WebRTCRemoteInputProtocolTests: XCTestCase {
    private let sessionID = UUID(uuidString: "8D18B56A-302A-4EC2-A3DA-1070491D7814")!
    private let targetGeneration = UUID(uuidString: "4FCB104A-E63D-4DC3-AF48-11702A24C232")!
    private let successorGeneration = UUID(uuidString: "84BA3C4F-E14C-4ED3-AE2C-D62A63CD28FD")!

    func testInputAuthorizationLinearizesRevocationAgainstInFlightWork() async throws {
        let authorization = WebRTCInputAuthorization()
        let operationEntered = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)

        let operation = Task.detached {
            try authorization.withValidAuthorization {
                operationEntered.signal()
                allowOperationToFinish.wait()
                return true
            }
        }
        XCTAssertEqual(operationEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            authorization.revoke()
            revocationFinished.signal()
        }
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 0.05), .timedOut)

        allowOperationToFinish.signal()
        let operationCompleted = try await operation.value
        XCTAssertTrue(operationCompleted)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
        XCTAssertThrowsError(
            try authorization.withValidAuthorization { XCTFail("Revoked work must not run.") }
        )
    }

    func testInputSendAuthorizationRejectsRevokedWorkWithoutRevokingSession() {
        let inputAuthorization = WebRTCInputAuthorization()
        let sendAuthorization = WebRTCInputSendAuthorization()
        sendAuthorization.revoke()

        XCTAssertThrowsError(
            try WebRTCInputSendAuthorizationOrder.withValidAuthorizations(
                inputAuthorization: inputAuthorization,
                sendAuthorization: sendAuthorization
            ) {
                XCTFail("A revoked configuration must not reach the final send boundary.")
            }
        ) { error in
            XCTAssertEqual(error as? WebRTCTransportError, .inputUnavailable)
        }
        XCTAssertTrue(inputAuthorization.isValid)
    }

    func testInputSendAuthorizationLinearizesRevocationAtFinalSendBoundary() async throws {
        let inputAuthorization = WebRTCInputAuthorization()
        let sendAuthorization = WebRTCInputSendAuthorization()
        let operationEntered = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let revocationFinished = DispatchSemaphore(value: 0)

        let operation = Task.detached {
            try WebRTCInputSendAuthorizationOrder.withValidAuthorizations(
                inputAuthorization: inputAuthorization,
                sendAuthorization: sendAuthorization
            ) {
                operationEntered.signal()
                allowOperationToFinish.wait()
                return true
            }
        }
        XCTAssertEqual(operationEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            sendAuthorization.revoke()
            revocationFinished.signal()
        }
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 0.05), .timedOut)

        allowOperationToFinish.signal()
        let operationCompleted = try await operation.value
        XCTAssertTrue(operationCompleted)
        XCTAssertEqual(revocationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(sendAuthorization.isValid)
        XCTAssertTrue(inputAuthorization.isValid)
        XCTAssertThrowsError(
            try WebRTCInputSendAuthorizationOrder.withValidAuthorizations(
                inputAuthorization: inputAuthorization,
                sendAuthorization: sendAuthorization
            ) {
                XCTFail("Revoked work must not run.")
            }
        )
    }

#if DEBUG
    func testViewerRejectsPrimaryDragWhenCapabilityDoesNotAdvertiseIt() async throws {
        let viewer = try WebRTCPeer(
            configuration: .init(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 10
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )

        do {
            _ = try await viewer.requestInput(
                .primaryDrag(
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.9)
                ),
                capability: capability,
                authorization: authorization
            )
            XCTFail("An unadvertised drag must not reach the native send boundary.")
        } catch WebRTCTransportError.invalidInputRequest {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(authorization.isValid)
        let activeCapability = await viewer.currentInputCapability()
        XCTAssertEqual(activeCapability, capability)
        await viewer.close(reason: .viewerDisconnected)
    }

    func testHostEnforcesPrimaryDragCapabilityWithoutChangingOtherInput() async throws {
        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let capabilityWithoutDrag = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 11
        )
        let rejectedAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capabilityWithoutDrag,
            authorization: rejectedAuthorization
        )

        let dragWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 1,
                screenRequestID: capabilityWithoutDrag.screenRequestID,
                inputSessionID: capabilityWithoutDrag.inputSessionID,
                action: .primaryDrag(
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.9)
                )
            )
        )
        XCTAssertFalse(dragWasAccepted)
        XCTAssertFalse(rejectedAuthorization.isValid)
        let capabilityAfterRejectedDrag = await host.currentInputCapability()
        XCTAssertNil(capabilityAfterRejectedDrag)

        let tapAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capabilityWithoutDrag,
            authorization: tapAuthorization
        )
        let tapWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 2,
                screenRequestID: capabilityWithoutDrag.screenRequestID,
                inputSessionID: capabilityWithoutDrag.inputSessionID,
                action: .tap(.init(x: 0.5, y: 0.5))
            )
        )
        XCTAssertTrue(tapWasAccepted)
        XCTAssertTrue(tapAuthorization.isValid)

        let capabilityWithDrag = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 12,
            supportsPrimaryDrag: true
        )
        let dragAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capabilityWithDrag,
            authorization: dragAuthorization
        )
        let advertisedDragWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 3,
                screenRequestID: capabilityWithDrag.screenRequestID,
                inputSessionID: capabilityWithDrag.inputSessionID,
                action: .primaryDrag(
                    start: .init(x: 0.2, y: 0.3),
                    end: .init(x: 0.7, y: 0.8)
                )
            )
        )
        XCTAssertTrue(advertisedDragWasAccepted)
        XCTAssertTrue(dragAuthorization.isValid)
        let activeCapability = await host.currentInputCapability()
        XCTAssertEqual(activeCapability, capabilityWithDrag)

        await host.close(reason: .hostStopped)
    }

    func testViewerRejectsScrollWhenCapabilityDoesNotAdvertiseIt() async throws {
        let viewer = try WebRTCPeer(
            configuration: .init(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 13
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )

        do {
            _ = try await viewer.requestInput(
                .scroll(
                    anchor: .init(x: 0.5, y: 0.5),
                    deltaX: -12,
                    deltaY: 48
                ),
                viewerVideoSize: .init(width: 1_080, height: 2_340),
                capability: capability,
                authorization: authorization
            )
            XCTFail("An unadvertised scroll must not reach the native send boundary.")
        } catch WebRTCTransportError.invalidInputRequest {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(authorization.isValid)
        let activeCapability = await viewer.currentInputCapability()
        XCTAssertEqual(activeCapability, capability)
        await viewer.close(reason: .viewerDisconnected)
    }

    func testHostEnforcesScrollCapability() async throws {
        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let capabilityWithoutScroll = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 14
        )
        let rejectedAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capabilityWithoutScroll,
            authorization: rejectedAuthorization
        )

        let scrollWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 1,
                screenRequestID: capabilityWithoutScroll.screenRequestID,
                inputSessionID: capabilityWithoutScroll.inputSessionID,
                action: .scroll(
                    anchor: .init(x: 0.5, y: 0.5),
                    deltaX: 0,
                    deltaY: 32
                ),
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        XCTAssertFalse(scrollWasAccepted)
        XCTAssertFalse(rejectedAuthorization.isValid)
        let capabilityAfterRejectedScroll = await host.currentInputCapability()
        XCTAssertNil(capabilityAfterRejectedScroll)

        let capabilityWithScroll = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 15,
            supportsScroll: true
        )
        let acceptedAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capabilityWithScroll,
            authorization: acceptedAuthorization
        )
        let advertisedScrollWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 2,
                screenRequestID: capabilityWithScroll.screenRequestID,
                inputSessionID: capabilityWithScroll.inputSessionID,
                action: .scroll(
                    anchor: .init(x: 0.25, y: 0.75),
                    deltaX: -24,
                    deltaY: 64
                ),
                viewerVideoSize: .init(width: 750, height: 1_334)
            )
        )
        XCTAssertTrue(advertisedScrollWasAccepted)
        XCTAssertTrue(acceptedAuthorization.isValid)
        let activeCapability = await host.currentInputCapability()
        XCTAssertEqual(activeCapability, capabilityWithScroll)

        await host.close(reason: .hostStopped)
    }

    func testFocusedWindowResizeRequiresAdvertisedCapabilityOnBothSides() async throws {
        let viewer = try WebRTCPeer(
            configuration: .init(role: .viewer, iceServers: [])
        )
        let disabledCapability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 16
        )
        let viewerAuthorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: disabledCapability,
            authorization: viewerAuthorization
        )

        do {
            _ = try await viewer.requestInput(
                .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 1_080, height: 2_340),
                capability: disabledCapability,
                authorization: viewerAuthorization
            )
            XCTFail("Unadvertised focused-window resize must not reach the send boundary.")
        } catch WebRTCTransportError.invalidInputRequest {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(viewerAuthorization.isValid)
        await viewer.close(reason: .viewerDisconnected)

        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let rejectedAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: disabledCapability,
            authorization: rejectedAuthorization
        )
        let unsupportedWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 1,
                screenRequestID: disabledCapability.screenRequestID,
                inputSessionID: disabledCapability.inputSessionID,
                action: .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        XCTAssertFalse(unsupportedWasAccepted)
        XCTAssertFalse(rejectedAuthorization.isValid)

        let enabledCapability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 17,
            supportsFocusedWindowResize: true
        )
        let acceptedAuthorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: enabledCapability,
            authorization: acceptedAuthorization
        )
        let advertisedWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 2,
                screenRequestID: enabledCapability.screenRequestID,
                inputSessionID: enabledCapability.inputSessionID,
                action: .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 750, height: 1_334)
            )
        )
        XCTAssertTrue(advertisedWasAccepted)
        XCTAssertTrue(acceptedAuthorization.isValid)
        await host.close(reason: .hostStopped)
    }

    func testHostSuppressesEquivalentCommitDuplicateAndFailsClosedOnConflictingGeneration()
        async throws {
        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 18,
            supportsFocusedWindowResize: true
        )
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )
        let first = WebRTCInputRequest(
            id: 40,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        let firstWasAccepted = await host.receiveInputRequestForTesting(first)
        XCTAssertTrue(firstWasAccepted)

        let equivalentDuplicate = WebRTCInputRequest(
            id: first.id,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.9, y: 0.8),
                end: .init(x: 0.2, y: 0.1)
            ),
            viewerVideoSize: .init(width: 750, height: 1_334)
        )
        let duplicateWasAccepted = await host.receiveInputRequestForTesting(
            equivalentDuplicate
        )
        XCTAssertTrue(duplicateWasAccepted)
        var snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 1)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 0)
        XCTAssertTrue(authorization.isValid)

        let conflictingGeneration = WebRTCInputRequest(
            id: first.id,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: successorGeneration,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        let conflictWasAccepted = await host.receiveInputRequestForTesting(
            conflictingGeneration
        )
        XCTAssertFalse(conflictWasAccepted)
        snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 0)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertFalse(authorization.isValid)
        let capabilityAfterConflict = await host.currentInputCapability()
        XCTAssertNil(capabilityAfterConflict)

        await host.close(reason: .hostStopped)
    }

    func testHostFailsClosedOnStaleFocusedWindowResizeRequestID() async throws {
        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 19,
            supportsFocusedWindowResize: true
        )
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )
        let firstWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 52,
                screenRequestID: capability.screenRequestID,
                inputSessionID: capability.inputSessionID,
                action: .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        XCTAssertTrue(firstWasAccepted)
        let staleWasAccepted = await host.receiveInputRequestForTesting(
            .init(
                id: 51,
                screenRequestID: capability.screenRequestID,
                inputSessionID: capability.inputSessionID,
                action: .selectWindowForResize(at: .init(x: 0.4, y: 0.6)),
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        XCTAssertFalse(staleWasAccepted)

        let snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 0)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertFalse(authorization.isValid)
        let capabilityAfterStaleRequest = await host.currentInputCapability()
        XCTAssertNil(capabilityAfterStaleRequest)

        await host.close(reason: .hostStopped)
    }

    func testHostReplaysCommittedResizeFeedbackWithoutReemittingApplicationWork()
        async throws {
        let host = try WebRTCPeer(
            configuration: .init(role: .host, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 20,
            supportsFocusedWindowResize: true
        )
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )
        await host.beginRemoteInputControlDataCaptureForTesting()

        let request = WebRTCInputRequest(
            id: 60,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.2, y: 0.3),
                end: .init(x: 0.7, y: 0.8)
            ),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        let requestWasAccepted = await host.receiveInputRequestForTesting(request)
        XCTAssertTrue(requestWasAccepted)
        let committed = WebRTCWindowResizeFeedback(
            kind: .resizeCommitted,
            committedTargetGeneration: targetGeneration,
            target: .init(
                generation: successorGeneration,
                normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
            )
        )
        try await host.sendInputFeedback(
            for: request.id,
            result: .accepted,
            focus: .none,
            windowResize: committed
        )

        let duplicate = WebRTCInputRequest(
            id: request.id,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.8, y: 0.7),
                end: .init(x: 0.3, y: 0.2)
            ),
            viewerVideoSize: .init(width: 750, height: 1_334)
        )
        let duplicateWasAccepted = await host.receiveInputRequestForTesting(duplicate)
        XCTAssertTrue(duplicateWasAccepted)

        let snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 1)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 1)
        XCTAssertEqual(snapshot.capturedControlData.count, 2)
        XCTAssertEqual(snapshot.capturedControlData[0], snapshot.capturedControlData[1])
        XCTAssertEqual(
            try snapshot.capturedControlData.map {
                try JSONDecoder().decode(ControlChannelMessage.self, from: $0)
            },
            [
                .inputFeedback(
                    .init(
                        id: request.id,
                        screenRequestID: capability.screenRequestID,
                        inputSessionID: capability.inputSessionID,
                        result: .accepted,
                        focus: .none,
                        windowResize: committed
                    )
                ),
                .inputFeedback(
                    .init(
                        id: request.id,
                        screenRequestID: capability.screenRequestID,
                        inputSessionID: capability.inputSessionID,
                        result: .accepted,
                        focus: .none,
                        windowResize: committed
                    )
                )
            ]
        )
        XCTAssertTrue(authorization.isValid)

        await host.close(reason: .hostStopped)
    }

    func testNativeEventBufferOverflowRevokesInputBeforePeerCanDrainBacklog() {
        let proxy = WebRTCDelegateProxy()
        let authorization = WebRTCInputAuthorization()
        proxy.markNativeTransportHealthyForTesting()
        XCTAssertTrue(proxy.installInputAuthorization(authorization))

        for _ in 0...256 {
            proxy.emitForTesting(.negotiationNeeded)
        }

        XCTAssertTrue(proxy.didFailEventDelivery())
        XCTAssertFalse(authorization.isValid)
        proxy.close()
    }

    func testNativeUnhealthyCallbacksRevokeInputBeforeEventDrain() {
        let transitions: [(WebRTCDelegateProxy, WebRTCInputAuthorization, () -> Void)] = [
            makeNativeTransition { $0.receivePeerStateForTesting(.disconnected) },
            makeNativeTransition { $0.receiveICEStateForTesting(.checking) },
            makeNativeTransition { $0.receiveDataChannelStateForTesting(.closing) },
            makeNativeTransition { $0.receiveControlProtocolFailureForTesting() }
        ]

        for (proxy, authorization, transition) in transitions {
            XCTAssertTrue(authorization.isValid)
            transition()
            // Deliberately never iterate proxy.events. Revocation belongs to the native callback.
            XCTAssertFalse(authorization.isValid)
            proxy.close()
        }
    }

    func testNativeBoundaryRejectsInstallingInputWhileTransportIsUnhealthy() {
        let proxy = WebRTCDelegateProxy()
        let authorization = WebRTCInputAuthorization()

        XCTAssertFalse(proxy.installInputAuthorization(authorization))
        XCTAssertFalse(authorization.isValid)
        proxy.close()
    }

    private func makeNativeTransition(
        _ transition: @escaping (WebRTCDelegateProxy) -> Void
    ) -> (WebRTCDelegateProxy, WebRTCInputAuthorization, () -> Void) {
        let proxy = WebRTCDelegateProxy()
        let authorization = WebRTCInputAuthorization()
        proxy.markNativeTransportHealthyForTesting()
        XCTAssertTrue(proxy.installInputAuthorization(authorization))
        return (proxy, authorization, { transition(proxy) })
    }
#endif

    func testEnvelopeRemainsVersionTwoAndUsesFixedInputKinds() throws {
        let request = WebRTCInputRequest(
            id: 7,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: .returnKey(focusGeneration: 9)
        )
        let data = try JSONEncoder().encode(ControlChannelMessage.input(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["kind"] as? String, "input")
        let encodedRequest = try XCTUnwrap(object["input"] as? [String: Any])
        let action = try XCTUnwrap(encodedRequest["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "return")
        XCTAssertNil(action["text"])
        XCTAssertNil(action["point"])
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            .input(request)
        )
    }

    func testPointerRequestBindsToViewerObservedVideoAspectWithoutChangingEnvelopeVersion() throws {
        let request = WebRTCInputRequest(
            id: 8,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: .tap(.init(x: 0.25, y: 0.75)),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )

        let data = try JSONEncoder().encode(ControlChannelMessage.input(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 2)
        let encodedRequest = try XCTUnwrap(object["input"] as? [String: Any])
        let encodedSize = try XCTUnwrap(
            encodedRequest["viewerVideoSize"] as? [String: Any]
        )
        XCTAssertEqual(encodedSize["width"] as? Int, 1_080)
        XCTAssertEqual(encodedSize["height"] as? Int, 2_340)
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            .input(request)
        )
    }

    func testLegacyPointerRequestWithoutViewerVideoSizeStillDecodes() throws {
        let data = Data(
            #"{"id":8,"screenRequestID":3,"inputSessionID":"8D18B56A-302A-4EC2-A3DA-1070491D7814","action":{"kind":"tap","point":{"x":0.25,"y":0.75}}}"#.utf8
        )

        let request = try JSONDecoder().decode(WebRTCInputRequest.self, from: data)

        XCTAssertNil(request.viewerVideoSize)
        XCTAssertEqual(request.action, .tap(.init(x: 0.25, y: 0.75)))
    }

    func testViewerVideoSizeIsRejectedForKeyboardAndOutsideSafeBounds() {
        let keyboardRequest = WebRTCInputRequest(
            id: 9,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: .returnKey(focusGeneration: 9),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        XCTAssertThrowsError(try JSONEncoder().encode(keyboardRequest))

        let invalidSizeRequest = WebRTCInputRequest(
            id: 10,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: .tap(.init(x: 0.5, y: 0.5)),
            viewerVideoSize: .init(width: 1, height: 2_340)
        )
        XCTAssertThrowsError(try JSONEncoder().encode(invalidSizeRequest))
    }

    func testScrollRequiresViewerVideoSize() throws {
        let action = WebRTCInputAction.scroll(
            anchor: .init(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 48
        )
        let missingSizeRequest = WebRTCInputRequest(
            id: 11,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: action
        )
        XCTAssertThrowsError(try JSONEncoder().encode(missingSizeRequest))
        let missingSizePayload = Data(
            #"{"id":11,"screenRequestID":3,"inputSessionID":"8D18B56A-302A-4EC2-A3DA-1070491D7814","action":{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":48}}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(WebRTCInputRequest.self, from: missingSizePayload)
        )

        let boundRequest = WebRTCInputRequest(
            id: 11,
            screenRequestID: 3,
            inputSessionID: sessionID,
            action: action,
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCInputRequest.self,
                from: JSONEncoder().encode(boundRequest)
            ),
            boundRequest
        )
    }

    func testFocusedWindowResizeActionsRequireViewerVideoSize() throws {
        let actions: [WebRTCInputAction] = [
            .requestFocusedWindowResizeTarget,
            .selectWindowForResize(at: .init(x: 0.25, y: 0.75)),
            .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.2, y: 0.3),
                end: .init(x: 0.6, y: 0.8)
            )
        ]

        for (offset, action) in actions.enumerated() {
            let missingSize = WebRTCInputRequest(
                id: UInt64(20 + offset),
                screenRequestID: 3,
                inputSessionID: sessionID,
                action: action
            )
            XCTAssertThrowsError(try JSONEncoder().encode(missingSize))

            let bound = WebRTCInputRequest(
                id: UInt64(20 + offset),
                screenRequestID: 3,
                inputSessionID: sessionID,
                action: action,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
            XCTAssertEqual(
                try JSONDecoder().decode(
                    WebRTCInputRequest.self,
                    from: JSONEncoder().encode(bound)
                ),
                bound
            )
        }
    }

    func testLegacyV2AcknowledgementWithoutCapabilityStillDecodes() throws {
        let data = Data(#"{"version":2,"kind":"ack","acknowledgement":{"id":4,"state":"active"}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            .acknowledgement(.init(id: 4, state: .active))
        )
    }

    func testCapabilityRoundTripsInsideActiveAcknowledgement() throws {
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 11,
            supportsPrimaryDrag: true,
            supportsScroll: true
        )
        let acknowledgement = WebRTCControlAcknowledgement(
            id: 11,
            state: .active,
            inputCapability: capability
        )
        let data = try JSONEncoder().encode(
            ControlChannelMessage.acknowledgement(acknowledgement)
        )
        XCTAssertLessThanOrEqual(data.count, WebRTCInputCapability.maximumMessageBytes)
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            .acknowledgement(acknowledgement)
        )
    }

    func testCapabilityDefaultsOptionalInputActionsToFalseForLegacyPayload() throws {
        let data = Data(
            #"{"protocolVersion":1,"inputSessionID":"8D18B56A-302A-4EC2-A3DA-1070491D7814","screenRequestID":11,"maxMessageBytes":4096}"#.utf8
        )

        let capability = try JSONDecoder().decode(WebRTCInputCapability.self, from: data)

        XCTAssertFalse(capability.supportsPrimaryDrag)
        XCTAssertFalse(capability.supportsScroll)
        XCTAssertFalse(capability.supportsFocusedWindowResize)
        XCTAssertEqual(capability.protocolVersion, WebRTCInputCapability.currentProtocolVersion)
    }

    func testCapabilityEncodesAndDecodesOptionalInputSupport() throws {
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 11,
            supportsPrimaryDrag: true,
            supportsScroll: true,
            supportsFocusedWindowResize: true
        )

        let data = try JSONEncoder().encode(capability)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["supportsPrimaryDrag"] as? Bool, true)
        XCTAssertEqual(object["supportsScroll"] as? Bool, true)
        XCTAssertEqual(object["supportsFocusedWindowResize"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputCapability.self, from: data), capability)
    }

    func testAllInputActionsRoundTrip() throws {
        let actions: [WebRTCInputAction] = [
            .tap(.init(x: 0, y: 1)),
            .primaryDrag(start: .init(x: 0.1, y: 0.2), end: .init(x: 0.8, y: 0.9)),
            .scroll(anchor: .init(x: 0.25, y: 0.75), deltaX: -32, deltaY: 96),
            .requestFocusedWindowResizeTarget,
            .selectWindowForResize(at: .init(x: 0.4, y: 0.6)),
            .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.2, y: 0.3),
                end: .init(x: 0.7, y: 0.8)
            ),
            .insertText("Hello 👋", focusGeneration: 2),
            .backspace(focusGeneration: 3),
            .returnKey(focusGeneration: 4)
        ]

        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: data), action)
        }
    }

    func testPrimaryDragUsesStrictWireShape() throws {
        let action = WebRTCInputAction.primaryDrag(
            start: .init(x: 0.1, y: 0.2),
            end: .init(x: 0.8, y: 0.9)
        )

        let data = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set(["kind", "start", "end"]))
        XCTAssertEqual(object["kind"] as? String, "primaryDrag")
        XCTAssertNotNil(object["start"] as? [String: Any])
        XCTAssertNotNil(object["end"] as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: data), action)
    }

    func testScrollUsesStrictWireShape() throws {
        let action = WebRTCInputAction.scroll(
            anchor: .init(x: 0.25, y: 0.75),
            deltaX: -32,
            deltaY: 96
        )

        let data = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set(["kind", "anchor", "deltaX", "deltaY"]))
        XCTAssertEqual(object["kind"] as? String, "scroll")
        XCTAssertNotNil(object["anchor"] as? [String: Any])
        XCTAssertEqual(object["deltaX"] as? Int, -32)
        XCTAssertEqual(object["deltaY"] as? Int, 96)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: data), action)
    }

    func testFocusedWindowResizeActionsUseDistinctStrictWireShapes() throws {
        let targetRequest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    WebRTCInputAction.requestFocusedWindowResizeTarget
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(targetRequest.keys), Set(["kind"]))
        XCTAssertEqual(targetRequest["kind"] as? String, "focusedWindowResizeTarget")

        let selection = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    WebRTCInputAction.selectWindowForResize(at: .init(x: 0.4, y: 0.6))
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(selection.keys), Set(["kind", "point"]))
        XCTAssertEqual(selection["kind"] as? String, "focusedWindowSelection")

        let commitAction = WebRTCInputAction.commitFocusedWindowResize(
            targetGeneration: targetGeneration,
            start: .init(x: 0.2, y: 0.3),
            end: .init(x: 0.7, y: 0.8)
        )
        let commit = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(commitAction)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(commit.keys),
            Set(["kind", "targetGeneration", "start", "end"])
        )
        XCTAssertEqual(commit["kind"] as? String, "focusedWindowResizeCommit")
        XCTAssertEqual(
            (commit["targetGeneration"] as? String)?.uppercased(),
            targetGeneration.uuidString
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCInputAction.self,
                from: JSONEncoder().encode(commitAction)
            ),
            commitAction
        )
    }

    func testRequestHistoryBindingDoesNotRetainCommittedText() {
        let sensitiveText = "never-retain-this-credential"
        let first = WebRTCInputRequestBinding(
            WebRTCInputRequest(
                id: 19,
                screenRequestID: 11,
                inputSessionID: sessionID,
                action: .insertText(sensitiveText, focusGeneration: 7)
            )
        )
        let second = WebRTCInputRequestBinding(
            WebRTCInputRequest(
                id: 19,
                screenRequestID: 11,
                inputSessionID: sessionID,
                action: .insertText("different text", focusGeneration: 7)
            )
        )

        XCTAssertEqual(first, second, "History identity is payload-blind and at-most-once by ID")
        XCTAssertFalse(String(reflecting: first).contains(sensitiveText))
    }

    func testRequestHistoryBindingRetainsOnlyActionKindAndCommitAuthority() {
        let baseRequest = WebRTCInputRequest(
            id: 20,
            screenRequestID: 11,
            inputSessionID: sessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        let sameAuthorityDifferentPointerPayload = WebRTCInputRequest(
            id: 20,
            screenRequestID: 11,
            inputSessionID: sessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: .init(x: 0.9, y: 0.8),
                end: .init(x: 0.2, y: 0.1)
            ),
            viewerVideoSize: .init(width: 750, height: 1_334)
        )
        let differentAuthority = WebRTCInputRequest(
            id: 20,
            screenRequestID: 11,
            inputSessionID: sessionID,
            action: .commitFocusedWindowResize(
                targetGeneration: successorGeneration,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )
        let differentAction = WebRTCInputRequest(
            id: 20,
            screenRequestID: 11,
            inputSessionID: sessionID,
            action: .requestFocusedWindowResizeTarget,
            viewerVideoSize: .init(width: 1_080, height: 2_340)
        )

        XCTAssertEqual(
            WebRTCInputRequestBinding(baseRequest),
            WebRTCInputRequestBinding(sameAuthorityDifferentPointerPayload)
        )
        XCTAssertNotEqual(
            WebRTCInputRequestBinding(baseRequest),
            WebRTCInputRequestBinding(differentAuthority)
        )
        XCTAssertNotEqual(
            WebRTCInputRequestBinding(baseRequest),
            WebRTCInputRequestBinding(differentAction)
        )
    }

    func testTextBoundaryAllows512UTF8And256UTF16CodeUnits() throws {
        let text = String(repeating: "😀", count: 128)
        XCTAssertEqual(text.utf8.count, 512)
        XCTAssertEqual(text.utf16.count, 256)
        let action = WebRTCInputAction.insertText(text, focusGeneration: 1)
        XCTAssertNoThrow(try JSONEncoder().encode(action))
    }

    func testTextRejectsEmptyOversizedControlAndFunctionKeyCharacters() {
        let invalidActions: [WebRTCInputAction] = [
            .insertText("", focusGeneration: 1),
            .insertText(String(repeating: "a", count: 257), focusGeneration: 1),
            .insertText(String(repeating: "€", count: 171), focusGeneration: 1),
            .insertText("line\nfeed", focusGeneration: 1),
            .insertText("tab\there", focusGeneration: 1),
            .insertText("delete\u{7F}", focusGeneration: 1),
            .insertText("c1\u{85}", focusGeneration: 1),
            .insertText("function\u{F700}", focusGeneration: 1),
            .insertText("function\u{F8FF}", focusGeneration: 1),
            .insertText("zero generation", focusGeneration: 0)
        ]

        for action in invalidActions {
            XCTAssertThrowsError(try JSONEncoder().encode(action), "Expected rejection for \(action)")
        }
    }

    func testTapRejectsNonFiniteAndOutOfRangeCoordinates() {
        let invalidPoints = [
            WebRTCNormalizedPoint(x: -.ulpOfOne, y: 0),
            WebRTCNormalizedPoint(x: 0, y: 1 + .ulpOfOne),
            WebRTCNormalizedPoint(x: .nan, y: 0),
            WebRTCNormalizedPoint(x: 0, y: .infinity)
        ]
        for point in invalidPoints {
            XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputAction.tap(point)))
        }
    }

    func testPrimaryDragEncoderRejectsInvalidStartOrEnd() {
        let invalidActions: [WebRTCInputAction] = [
            .primaryDrag(start: .init(x: -.ulpOfOne, y: 0), end: .init(x: 1, y: 1)),
            .primaryDrag(start: .init(x: 0, y: 0), end: .init(x: 1 + .ulpOfOne, y: 1)),
            .primaryDrag(start: .init(x: .nan, y: 0), end: .init(x: 1, y: 1)),
            .primaryDrag(start: .init(x: 0, y: 0), end: .init(x: 1, y: .infinity))
        ]

        for action in invalidActions {
            XCTAssertThrowsError(try JSONEncoder().encode(action))
        }
    }

    func testPrimaryDragDecoderRejectsMalformedMixedAndOutOfRangePayloads() {
        let invalidPayloads = [
            #"{"kind":"primaryDrag","end":{"x":0.8,"y":0.9}}"#,
            #"{"kind":"primaryDrag","start":{"x":0.1,"y":0.2}}"#,
            #"{"kind":"primaryDrag","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9},"point":{"x":0.5,"y":0.5}}"#,
            #"{"kind":"primaryDrag","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9},"text":"mixed"}"#,
            #"{"kind":"primaryDrag","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9},"focusGeneration":1}"#,
            #"{"kind":"primaryDrag","start":{"x":-0.1,"y":0.2},"end":{"x":0.8,"y":0.9}}"#,
            #"{"kind":"primaryDrag","start":{"x":0.1,"y":0.2},"end":{"x":1.1,"y":0.9}}"#
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(WebRTCInputAction.self, from: Data(payload.utf8)),
                "Expected rejection for \(payload)"
            )
        }
    }

    func testScrollEncoderRejectsInvalidAnchorZeroAndOutOfRangeDeltas() {
        let maximum = WebRTCInputAction.maximumScrollDeltaMagnitude
        let invalidActions: [WebRTCInputAction] = [
            .scroll(anchor: .init(x: -.ulpOfOne, y: 0.5), deltaX: 0, deltaY: 1),
            .scroll(anchor: .init(x: 0.5, y: 0.5), deltaX: 0, deltaY: 0),
            .scroll(anchor: .init(x: 0.5, y: 0.5), deltaX: maximum + 1, deltaY: 0),
            .scroll(anchor: .init(x: 0.5, y: 0.5), deltaX: 0, deltaY: -maximum - 1)
        ]

        for action in invalidActions {
            XCTAssertThrowsError(try JSONEncoder().encode(action))
        }
    }

    func testScrollDecoderRejectsMalformedMixedZeroAndOutOfRangePayloads() {
        let invalidPayloads = [
            #"{"kind":"scroll","deltaX":0,"deltaY":1}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaY":1}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":0}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":4097,"deltaY":0}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":-4097}"#,
            #"{"kind":"scroll","anchor":{"x":1.1,"y":0.5},"deltaX":0,"deltaY":1}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":1,"point":{"x":0.5,"y":0.5}}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":1,"start":{"x":0.1,"y":0.1}}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":1,"text":"mixed"}"#,
            #"{"kind":"scroll","anchor":{"x":0.5,"y":0.5},"deltaX":2147483648,"deltaY":1}"#
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(WebRTCInputAction.self, from: Data(payload.utf8)),
                "Expected rejection for \(payload)"
            )
        }
    }

    func testFocusedWindowResizeDecoderRejectsMalformedMixedAndZeroAuthorityActions() {
        let invalidPayloads = [
            #"{"kind":"focusedWindowResizeTarget","point":{"x":0.5,"y":0.5}}"#,
            #"{"kind":"focusedWindowSelection"}"#,
            #"{"kind":"focusedWindowSelection","point":{"x":0.5,"y":0.5},"targetGeneration":"4FCB104A-E63D-4DC3-AF48-11702A24C232"}"#,
            #"{"kind":"focusedWindowResizeCommit","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9}}"#,
            #"{"kind":"focusedWindowResizeCommit","targetGeneration":"00000000-0000-0000-0000-000000000000","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9}}"#,
            #"{"kind":"focusedWindowResizeCommit","targetGeneration":"4FCB104A-E63D-4DC3-AF48-11702A24C232","start":{"x":0.1,"y":0.2},"end":{"x":0.8,"y":0.9},"point":{"x":0.5,"y":0.5}}"#,
            #"{"kind":"focusedWindowResizeCommit","targetGeneration":"4FCB104A-E63D-4DC3-AF48-11702A24C232","start":{"x":-0.1,"y":0.2},"end":{"x":0.8,"y":0.9}}"#
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(WebRTCInputAction.self, from: Data(payload.utf8)),
                "Expected rejection for \(payload)"
            )
        }

        let requestWithoutVideoSize = Data(
            #"{"id":30,"screenRequestID":3,"inputSessionID":"8D18B56A-302A-4EC2-A3DA-1070491D7814","action":{"kind":"focusedWindowResizeTarget"}}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(WebRTCInputRequest.self, from: requestWithoutVideoSize)
        )
    }

    func testDecoderRejectsMixedActionPayloadsAndControlText() {
        let mixed = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"focusGeneration":1}"#.utf8)
        let tapWithDrag = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"start":{"x":0.1,"y":0.1},"end":{"x":0.9,"y":0.9}}"#.utf8)
        let tapWithScroll = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"deltaX":0,"deltaY":1}"#.utf8)
        let newline = Data(#"{"kind":"text","text":"line\nfeed","focusGeneration":1}"#.utf8)
        let zeroGeneration = Data(#"{"kind":"backspace","focusGeneration":0}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: mixed))
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: tapWithDrag))
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: tapWithScroll))
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: newline))
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: zeroGeneration))
    }

    func testFeedbackRequiresReasonExactlyWhenRejectedAndValidFocusGeneration() throws {
        let accepted = WebRTCInputFeedback(
            id: 1,
            screenRequestID: 2,
            inputSessionID: sessionID,
            result: .accepted,
            focus: .editable(generation: 5, secure: true)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCInputFeedback.self,
                from: JSONEncoder().encode(accepted)
            ),
            accepted
        )

        let rejected = WebRTCInputFeedback(
            id: 2,
            screenRequestID: 2,
            inputSessionID: sessionID,
            result: .rejected,
            rejectionReason: .invalidFocus
        )
        let legacyCompatibleRejectedData = try JSONEncoder().encode(rejected)
        let legacyCompatibleRejectedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyCompatibleRejectedData)
                as? [String: Any]
        )
        XCTAssertNil(legacyCompatibleRejectedObject["screenFormatChanging"])
        XCTAssertFalse(
            try JSONDecoder().decode(
                WebRTCInputFeedback.self,
                from: legacyCompatibleRejectedData
            ).screenFormatChanging
        )

        let formatTransition = WebRTCInputFeedback(
            id: 3,
            screenRequestID: 2,
            inputSessionID: sessionID,
            result: .rejected,
            rejectionReason: .rateLimited,
            screenFormatChanging: true
        )
        let formatTransitionData = try JSONEncoder().encode(formatTransition)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCInputFeedback.self,
                from: formatTransitionData
            ),
            formatTransition
        )
        XCTAssertTrue(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: formatTransitionData)
                    as? [String: Any]
            )["screenFormatChanging"] as? Bool == true
        )

        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 4,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .rejected
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 5,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .accepted,
                    rejectionReason: .rateLimited
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 6,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .accepted,
                    focus: .editable(generation: 0, secure: false)
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 7,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .rejected,
                    rejectionReason: .invalidFocus,
                    screenFormatChanging: true
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 8,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .accepted,
                    screenFormatChanging: true
                )
            )
        )
    }

    func testFocusedWindowResizeFeedbackUsesStrictCommitEchoAndFreshSuccessor() throws {
        let target = WebRTCWindowResizeTarget(
            generation: successorGeneration,
            normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        )
        let committed = WebRTCWindowResizeFeedback(
            kind: .resizeCommitted,
            committedTargetGeneration: targetGeneration,
            target: target
        )
        let data = try JSONEncoder().encode(committed)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["kind", "committedTargetGeneration", "target"])
        )
        XCTAssertEqual(object["kind"] as? String, "resizeCommitted")
        XCTAssertEqual(
            (object["committedTargetGeneration"] as? String)?.uppercased(),
            targetGeneration.uuidString
        )
        XCTAssertEqual(
            try JSONDecoder().decode(WebRTCWindowResizeFeedback.self, from: data),
            committed
        )

        let acquired = WebRTCWindowResizeFeedback(kind: .targetAcquired, target: target)
        let acquiredObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(acquired)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(acquiredObject.keys), Set(["kind", "target"]))

        let invalid = [
            WebRTCWindowResizeFeedback(kind: .resizeCommitted, target: target),
            WebRTCWindowResizeFeedback(
                kind: .targetAcquired,
                committedTargetGeneration: targetGeneration,
                target: target
            ),
            WebRTCWindowResizeFeedback(
                kind: .resizeCommitted,
                committedTargetGeneration: successorGeneration,
                target: target
            ),
            WebRTCWindowResizeFeedback(
                kind: .resizeCommitted,
                committedTargetGeneration: UUID(
                    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                ),
                target: target
            )
        ]
        for feedback in invalid {
            XCTAssertThrowsError(try JSONEncoder().encode(feedback))
        }

        let missingCommitEcho = Data(
            #"{"kind":"resizeCommitted","target":{"generation":"84BA3C4F-E14C-4ED3-AE2C-D62A63CD28FD","normalizedFrame":{"x":0.1,"y":0.2,"width":0.6,"height":0.7}}}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WebRTCWindowResizeFeedback.self,
                from: missingCommitEcho
            )
        )
    }

    func testFocusedWindowResizeFeedbackIsBoundToExactRequestStageAndCommitAuthority() {
        let target = WebRTCWindowResizeTarget(
            generation: successorGeneration,
            normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        )
        let targetBinding = WebRTCInputRequestBinding(
            WebRTCInputRequest(
                id: 31,
                screenRequestID: 11,
                inputSessionID: sessionID,
                action: .requestFocusedWindowResizeTarget,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        let targetFeedback = WebRTCInputFeedback(
            id: 31,
            screenRequestID: 11,
            inputSessionID: sessionID,
            result: .accepted,
            focus: .editable(generation: 5, secure: false),
            windowResize: .init(kind: .targetAcquired, target: target)
        )
        XCTAssertTrue(targetBinding.permits(targetFeedback))
        XCTAssertFalse(
            targetBinding.permits(
                WebRTCInputFeedback(
                    id: 31,
                    screenRequestID: 11,
                    inputSessionID: sessionID,
                    result: .accepted,
                    windowResize: .init(kind: .windowSelected, target: target)
                )
            )
        )

        let commitBinding = WebRTCInputRequestBinding(
            WebRTCInputRequest(
                id: 32,
                screenRequestID: 11,
                inputSessionID: sessionID,
                action: .commitFocusedWindowResize(
                    targetGeneration: targetGeneration,
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.9)
                ),
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            )
        )
        let committedFeedback = WebRTCInputFeedback(
            id: 32,
            screenRequestID: 11,
            inputSessionID: sessionID,
            result: .accepted,
            focus: .editable(generation: 5, secure: false),
            windowResize: .init(
                kind: .resizeCommitted,
                committedTargetGeneration: targetGeneration,
                target: target
            )
        )
        XCTAssertTrue(commitBinding.permits(committedFeedback))

        let wrongEcho = WebRTCInputFeedback(
            id: 32,
            screenRequestID: 11,
            inputSessionID: sessionID,
            result: .accepted,
            windowResize: .init(
                kind: .resizeCommitted,
                committedTargetGeneration: sessionID,
                target: target
            )
        )
        XCTAssertFalse(commitBinding.permits(wrongEcho))

        let rejected = WebRTCInputFeedback(
            id: 32,
            screenRequestID: 11,
            inputSessionID: sessionID,
            result: .rejected,
            rejectionReason: .invalidRequest
        )
        XCTAssertTrue(commitBinding.permits(rejected))

        let ordinaryBinding = WebRTCInputRequestBinding(
            WebRTCInputRequest(
                id: 33,
                screenRequestID: 11,
                inputSessionID: sessionID,
                action: .tap(.init(x: 0.5, y: 0.5))
            )
        )
        XCTAssertFalse(
            ordinaryBinding.permits(
                WebRTCInputFeedback(
                    id: 33,
                    screenRequestID: 11,
                    inputSessionID: sessionID,
                    result: .accepted,
                    windowResize: .init(kind: .targetAcquired, target: target)
                )
            )
        )
    }

    func testNormalizedResizeTargetRejectsZeroAuthorityAndInvalidFrame() {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let invalidTargets = [
            WebRTCWindowResizeTarget(
                generation: zero,
                normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
            ),
            WebRTCWindowResizeTarget(
                generation: targetGeneration,
                normalizedFrame: .init(x: 0.8, y: 0.2, width: 0.3, height: 0.7)
            ),
            WebRTCWindowResizeTarget(
                generation: targetGeneration,
                normalizedFrame: .init(x: 0.1, y: 0.2, width: .nan, height: 0.7)
            )
        ]

        for target in invalidTargets {
            XCTAssertThrowsError(try JSONEncoder().encode(target))
        }
    }

    func testCapabilityRejectsWrongVersionSizeAndZeroIdentifiers() {
        let invalid = [
            WebRTCInputCapability(
                inputSessionID: sessionID,
                screenRequestID: 1,
                protocolVersion: 2
            ),
            WebRTCInputCapability(
                inputSessionID: sessionID,
                screenRequestID: 1,
                maxMessageBytes: 4_095
            ),
            WebRTCInputCapability(inputSessionID: sessionID, screenRequestID: 0),
            WebRTCInputCapability(
                inputSessionID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                screenRequestID: 1
            )
        ]

        for capability in invalid {
            XCTAssertThrowsError(try JSONEncoder().encode(capability))
        }
    }
}
