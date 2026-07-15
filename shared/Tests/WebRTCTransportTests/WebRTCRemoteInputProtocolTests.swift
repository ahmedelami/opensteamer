import Foundation
import Dispatch
@testable import WebRTCTransport
import XCTest

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
            screenRequestID: 11
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

    func testAllInputActionsRoundTrip() throws {
        let actions: [WebRTCInputAction] = [
            .tap(.init(x: 0, y: 1)),
            .insertText("Hello 👋", focusGeneration: 2),
            .backspace(focusGeneration: 3),
            .returnKey(focusGeneration: 4)
        ]

        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputAction.self, from: data), action)
        }
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

    func testDecoderRejectsMixedActionPayloadsAndControlText() {
        let mixed = Data(#"{"kind":"tap","point":{"x":0.5,"y":0.5},"focusGeneration":1}"#.utf8)
        let newline = Data(#"{"kind":"text","text":"line\nfeed","focusGeneration":1}"#.utf8)
        let zeroGeneration = Data(#"{"kind":"backspace","focusGeneration":0}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: mixed))
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
