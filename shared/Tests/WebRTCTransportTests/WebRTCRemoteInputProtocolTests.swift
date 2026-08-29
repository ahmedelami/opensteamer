import Foundation
import Dispatch
@testable import WebRTCTransport
import XCTest

/// Proves strict remote-input wire shapes, capability and focus binding, secret-text non-retention,
/// and synchronous authorization revocation at native and actor boundaries.
final class WebRTCRemoteInputProtocolTests: XCTestCase {
    private let sessionID = UUID(uuidString: "8D18B56A-302A-4EC2-A3DA-1070491D7814")!

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

    func testCapabilityDefaultsAdditivePointerFeaturesToFalseForLegacyPayload() throws {
        let data = Data(
            #"{"protocolVersion":1,"inputSessionID":"8D18B56A-302A-4EC2-A3DA-1070491D7814","screenRequestID":11,"maxMessageBytes":4096}"#.utf8
        )

        let capability = try JSONDecoder().decode(WebRTCInputCapability.self, from: data)

        XCTAssertFalse(capability.supportsPrimaryDrag)
        XCTAssertFalse(capability.supportsScroll)
        XCTAssertEqual(capability.protocolVersion, WebRTCInputCapability.currentProtocolVersion)
    }

    func testCapabilityEncodesAndDecodesPointerFeatureSupport() throws {
        let capability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 11,
            supportsPrimaryDrag: true,
            supportsScroll: true
        )

        let data = try JSONEncoder().encode(capability)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["supportsPrimaryDrag"] as? Bool, true)
        XCTAssertEqual(object["supportsScroll"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputCapability.self, from: data), capability)
    }

    func testAllInputActionsRoundTrip() throws {
        let actions: [WebRTCInputAction] = [
            .tap(.init(x: 0, y: 1)),
            .primaryDrag(start: .init(x: 0.1, y: 0.2), end: .init(x: 0.8, y: 0.9)),
            .scroll(anchor: .init(x: 0.5, y: 0.5), deltaX: 0.1, deltaY: -0.2),
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

    func testScrollUsesStrictWireShapeAndRejectsInvalidDeltas() throws {
        let action = WebRTCInputAction.scroll(
            anchor: .init(x: 0.25, y: 0.75),
            deltaX: 0.1,
            deltaY: -0.2
        )
        let data = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set(["kind", "anchor", "deltaX", "deltaY"]))
        XCTAssertEqual(object["kind"] as? String, "scroll")
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: data), action)

        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputAction.scroll(
                    anchor: .init(x: 0.5, y: 0.5),
                    deltaX: .infinity,
                    deltaY: 0
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputAction.scroll(
                    anchor: .init(x: 0.5, y: 0.5),
                    deltaX: 0,
                    deltaY: 0
                )
            )
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

    func testDecoderRejectsMixedActionPayloadsAndControlText() {
        let mixed = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"focusGeneration":1}"#.utf8)
        let tapWithDrag = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"start":{"x":0.1,"y":0.1},"end":{"x":0.9,"y":0.9}}"#.utf8)
        let newline = Data(#"{"kind":"text","text":"line\nfeed","focusGeneration":1}"#.utf8)
        let zeroGeneration = Data(#"{"kind":"backspace","focusGeneration":0}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: mixed))
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: tapWithDrag))
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
        XCTAssertNoThrow(try JSONEncoder().encode(rejected))

        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 3,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .rejected
                )
            )
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(
                WebRTCInputFeedback(
                    id: 4,
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
                    id: 5,
                    screenRequestID: 2,
                    inputSessionID: sessionID,
                    result: .accepted,
                    focus: .editable(generation: 0, secure: false)
                )
            )
        )
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
