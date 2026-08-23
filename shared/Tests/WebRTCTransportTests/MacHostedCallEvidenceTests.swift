import Foundation
@testable import WebRTCTransport
import XCTest

final class MacHostedCallEvidenceTests: XCTestCase {
    func testNativeObservationSendPolicyRejectsForcedOvertakeForSameBinding() {
        XCTAssertTrue(
            WebRTCMacHostedCallObservationSendPolicy.admits(
                observationSequence: 12,
                highestSentSequence: 0,
                bindingMatches: true
            )
        )
        XCTAssertFalse(
            WebRTCMacHostedCallObservationSendPolicy.admits(
                observationSequence: 11,
                highestSentSequence: 12,
                bindingMatches: true
            )
        )
        XCTAssertTrue(
            WebRTCMacHostedCallObservationSendPolicy.admits(
                observationSequence: 1,
                highestSentSequence: 12,
                bindingMatches: false
            )
        )
        XCTAssertFalse(
            WebRTCMacHostedCallObservationSendPolicy.admits(
                observationSequence: 0,
                highestSentSequence: 0,
                bindingMatches: false
            )
        )
    }

    func testEvidenceAuthorizationRevocationIsSynchronousAndHeldAcrossClosure()
        throws {
        let authorization = WebRTCMacHostedCallEvidenceAuthorization(
            callEpochNonce: UUID()
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(
            try authorization.withValidAuthorization { 42 },
            42
        )

        let operationEntered = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let operationReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? authorization.withValidAuthorization {
                operationEntered.signal()
                releaseOperation.wait()
            }
            operationReturned.signal()
        }
        XCTAssertEqual(
            operationEntered.wait(timeout: .now() + 1),
            .success
        )

        let revocationStarted = DispatchSemaphore(value: 0)
        let revocationReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            revocationStarted.signal()
            authorization.revoke()
            revocationReturned.signal()
        }
        XCTAssertEqual(
            revocationStarted.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            revocationReturned.wait(timeout: .now() + 0.05),
            .timedOut,
            "Revocation must linearize after a closure already holding the authorization lock."
        )

        releaseOperation.signal()
        XCTAssertEqual(
            operationReturned.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            revocationReturned.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertFalse(authorization.isValid)
        XCTAssertThrowsError(
            try authorization.withValidAuthorization {}
        ) { error in
            XCTAssertEqual(
                error as? WebRTCTransportError,
                .macHostedCallEvidenceAuthorizationRevoked
            )
        }
    }

    func testEvidenceSendAcquiresAudioAuthorizationBeforeEvidenceAuthorization()
        throws {
        let audioAuthorization = WebRTCAudioAuthorization()
        let callEpochNonce = UUID()
        let evidenceAuthorization =
            WebRTCMacHostedCallEvidenceAuthorization(
                callEpochNonce: callEpochNonce
            )
        let evidenceLockEntered = DispatchSemaphore(value: 0)
        let releaseEvidenceLock = DispatchSemaphore(value: 0)
        let evidenceLockReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = try? evidenceAuthorization.withValidAuthorization {
                evidenceLockEntered.signal()
                releaseEvidenceLock.wait()
            }
            evidenceLockReturned.signal()
        }
        XCTAssertEqual(
            evidenceLockEntered.wait(timeout: .now() + 1),
            .success
        )

        let audioLockEntered = DispatchSemaphore(value: 0)
        let sendOperationEntered = DispatchSemaphore(value: 0)
        let sendReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? WebRTCMacHostedCallEvidenceAuthorizationOrder
                .withValidAuthorizations(
                    audioAuthorization: audioAuthorization,
                    evidenceAuthorization: evidenceAuthorization,
                    expectedCallEpochNonce: callEpochNonce,
                    afterAudioAuthorizationAcquired: {
                        audioLockEntered.signal()
                    }
                ) {
                    sendOperationEntered.signal()
                }
            sendReturned.signal()
        }

        XCTAssertEqual(
            audioLockEntered.wait(timeout: .now() + 1),
            .success,
            "A send must acquire audio before waiting on the contended evidence lock."
        )
        XCTAssertEqual(
            sendOperationEntered.wait(timeout: .now() + 0.05),
            .timedOut
        )

        releaseEvidenceLock.signal()
        XCTAssertEqual(
            evidenceLockReturned.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            sendOperationEntered.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(
            sendReturned.wait(timeout: .now() + 1),
            .success
        )
    }

    func testEvidenceAuthorizationIsReusableOnlyWithinItsExactCallEpoch()
        throws {
        let callEpochNonce = UUID()
        let authorization = WebRTCAudioAuthorization()
        let evidenceAuthorization =
            WebRTCMacHostedCallEvidenceAuthorization(
                callEpochNonce: callEpochNonce
            )
        let firstChallenge = WebRTCMacHostedCallChallenge(
            sequence: 1,
            callEpochNonce: callEpochNonce
        )
        let rotatedChallenge = WebRTCMacHostedCallChallenge(
            sequence: 2,
            callEpochNonce: callEpochNonce
        )

        XCTAssertEqual(
            try WebRTCMacHostedCallEvidenceAuthorizationOrder
                .withValidAuthorizations(
                    audioAuthorization: authorization,
                    evidenceAuthorization: evidenceAuthorization,
                    expectedCallEpochNonce:
                        firstChallenge.callEpochNonce
                ) { 1 },
            1
        )
        XCTAssertEqual(
            try WebRTCMacHostedCallEvidenceAuthorizationOrder
                .withValidAuthorizations(
                    audioAuthorization: authorization,
                    evidenceAuthorization: evidenceAuthorization,
                    expectedCallEpochNonce:
                        rotatedChallenge.callEpochNonce
                ) { 2 },
            2,
            "A challenge rotation in the same call epoch must reuse the causal proof token."
        )

        XCTAssertThrowsError(
            try WebRTCMacHostedCallEvidenceAuthorizationOrder
                .withValidAuthorizations(
                    audioAuthorization: authorization,
                    evidenceAuthorization: evidenceAuthorization,
                    expectedCallEpochNonce: UUID()
                ) {}
        ) { error in
            XCTAssertEqual(
                error as? WebRTCTransportError,
                .transportNotHealthy
            )
        }
        XCTAssertTrue(
            evidenceAuthorization.isValid,
            "A wrong-epoch attempt must fail without revoking the proof owned by its real epoch."
        )
    }

    func testAdvertisingViewerSupportInsertsSessionAttributeBeforeFirstMediaSection() {
        let input = [
            "v=0",
            "o=- 1 1 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:audio"
        ].joined(separator: "\n")

        XCTAssertEqual(
            MacHostedCallEvidenceSDP.advertisingHostSupport(in: input),
            [
                "v=0",
                "o=- 1 1 IN IP4 127.0.0.1",
                "s=-",
                "t=0 0",
                "a=x-opensteamer-mac-hosted-call-evidence:4",
                "m=audio 9 UDP/TLS/RTP/SAVPF 111",
                "a=mid:audio"
            ].joined(separator: "\n")
        )
    }

    func testAdvertisingViewerSupportPreservesLineEndingsAndTrailingSeparator() {
        for separator in ["\n", "\r\n"] {
            for hasTrailingSeparator in [false, true] {
                let inputLines = [
                    "v=0",
                    "s=-",
                    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
                    "a=mid:audio"
                ]
                let input = inputLines.joined(separator: separator)
                    + (hasTrailingSeparator ? separator : "")
                let expected = [
                    "v=0",
                    "s=-",
                    "a=x-opensteamer-mac-hosted-call-evidence:4",
                    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
                    "a=mid:audio"
                ].joined(separator: separator)
                    + (hasTrailingSeparator ? separator : "")

                XCTAssertEqual(
                    MacHostedCallEvidenceSDP.advertisingHostSupport(in: input),
                    expected,
                    "separator=\(separator.debugDescription), trailing=\(hasTrailingSeparator)"
                )
                XCTAssertTrue(
                    MacHostedCallEvidenceSDP.peerSupportsEvidence(in: expected),
                    "separator=\(separator.debugDescription), trailing=\(hasTrailingSeparator)"
                )
            }
        }
    }

    func testViewerSupportMustBeAdvertisedAtSessionLevel() throws {
        let mediaLevelOnly = [
            "v=0",
            "s=-",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=x-opensteamer-mac-hosted-call-evidence:4",
            "a=mid:audio"
        ].joined(separator: "\r\n")

        XCTAssertFalse(
            MacHostedCallEvidenceSDP.peerSupportsEvidence(in: mediaLevelOnly)
        )

        let advertised = MacHostedCallEvidenceSDP.advertisingHostSupport(
            in: mediaLevelOnly
        )
        XCTAssertTrue(MacHostedCallEvidenceSDP.peerSupportsEvidence(in: advertised))
        XCTAssertEqual(
            advertised.components(
                separatedBy: "a=x-opensteamer-mac-hosted-call-evidence:4"
            ).count - 1,
            2
        )
        let attributeRange = try XCTUnwrap(
            advertised.range(of: "a=x-opensteamer-mac-hosted-call-evidence:4")
        )
        let mediaRange = try XCTUnwrap(advertised.range(of: "m=audio"))
        XCTAssertLessThan(
            attributeRange.lowerBound,
            mediaRange.lowerBound
        )
    }

    func testAdvertisingViewerSupportIsIdempotent() {
        let input = [
            "v=0",
            "s=-",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:audio",
            ""
        ].joined(separator: "\r\n")

        let once = MacHostedCallEvidenceSDP.advertisingHostSupport(in: input)
        let twice = MacHostedCallEvidenceSDP.advertisingHostSupport(in: once)

        XCTAssertEqual(twice, once)
        XCTAssertEqual(
            once.components(
                separatedBy: "a=x-opensteamer-mac-hosted-call-evidence:4"
            ).count - 1,
            1
        )
    }

    func testViewerSupportRejectsWrongProtocolVersion() {
        let wrongVersion = [
            "v=0",
            "a=x-opensteamer-mac-hosted-call-evidence:3",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111"
        ].joined(separator: "\n")

        XCTAssertFalse(MacHostedCallEvidenceSDP.peerSupportsEvidence(in: wrongVersion))

        let advertised = MacHostedCallEvidenceSDP.advertisingHostSupport(
            in: wrongVersion
        )
        XCTAssertTrue(MacHostedCallEvidenceSDP.peerSupportsEvidence(in: advertised))
        XCTAssertTrue(advertised.contains("a=x-opensteamer-mac-hosted-call-evidence:3"))
        XCTAssertTrue(advertised.contains("a=x-opensteamer-mac-hosted-call-evidence:4"))
    }

    func testEvidenceValidityRequiresCurrentProtocolAndEveryIdentity() {
        let nonce = UUID()
        let callEpochNonce = UUID()
        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        XCTAssertTrue(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 1,
                challengeNonce: nonce,
                callEpochNonce: callEpochNonce,
                state: .active
            ).isValid
        )
        XCTAssertTrue(
            WebRTCMacHostedCallEvidence(
                sequence: UInt64.max,
                challengeSequence: UInt64.max,
                challengeNonce: nonce,
                callEpochNonce: callEpochNonce,
                state: .inactive
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 0,
                challengeSequence: 1,
                challengeNonce: nonce,
                callEpochNonce: callEpochNonce,
                state: .active
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 0,
                challengeNonce: nonce,
                callEpochNonce: callEpochNonce,
                state: .active
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 1,
                challengeNonce: nonce,
                callEpochNonce: callEpochNonce,
                state: .active,
                protocolVersion:
                    WebRTCMacHostedCallEvidence.currentProtocolVersion + 1
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 1,
                challengeNonce: zeroUUID,
                callEpochNonce: callEpochNonce,
                state: .active
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 1,
                challengeNonce: nonce,
                callEpochNonce: zeroUUID,
                state: .active
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: 1,
                challengeNonce: nonce,
                callEpochNonce: nonce,
                state: .active
            ).isValid
        )
    }

    func testChallengeValidityRequiresCurrentProtocolAndEveryIdentity() {
        let nonce = UUID()
        let callEpochNonce = UUID()
        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )

        XCTAssertTrue(
            WebRTCMacHostedCallChallenge(
                sequence: 1,
                callEpochNonce: callEpochNonce,
                nonce: nonce
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallChallenge(
                sequence: 0,
                callEpochNonce: callEpochNonce,
                nonce: nonce
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallChallenge(
                sequence: 1,
                callEpochNonce: zeroUUID,
                nonce: nonce
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallChallenge(
                sequence: 1,
                callEpochNonce: callEpochNonce,
                nonce: zeroUUID
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallChallenge(
                sequence: 1,
                callEpochNonce: nonce,
                nonce: nonce
            ).isValid
        )
        XCTAssertFalse(
            WebRTCMacHostedCallChallenge(
                sequence: 1,
                callEpochNonce: callEpochNonce,
                nonce: nonce,
                protocolVersion:
                    WebRTCMacHostedCallChallenge.currentProtocolVersion - 1
            ).isValid
        )
    }

    func testEvidenceMatchesEveryChallengeIdentityIncludingCallEpoch() {
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: 7,
            callEpochNonce: UUID()
        )
        let matching = WebRTCMacHostedCallEvidence(
            sequence: 1,
            challengeSequence: challenge.sequence,
            challengeNonce: challenge.nonce,
            callEpochNonce: challenge.callEpochNonce,
            state: .preflightArmed
        )
        XCTAssertTrue(matching.matches(challenge))

        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: challenge.sequence + 1,
                challengeNonce: challenge.nonce,
                callEpochNonce: challenge.callEpochNonce,
                state: .active
            ).matches(challenge)
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 3,
                challengeSequence: challenge.sequence,
                challengeNonce: UUID(),
                callEpochNonce: challenge.callEpochNonce,
                state: .active
            ).matches(challenge)
        )
        XCTAssertFalse(
            WebRTCMacHostedCallEvidence(
                sequence: 4,
                challengeSequence: challenge.sequence,
                challengeNonce: challenge.nonce,
                callEpochNonce: UUID(),
                state: .active
            ).matches(challenge)
        )
    }

    func testEvidenceControlMessageRoundTripsInsideStrictVersionTwoEnvelope() throws {
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: 7,
            callEpochNonce: UUID()
        )
        let evidence = WebRTCMacHostedCallEvidence(
            sequence: 42,
            challengeSequence: challenge.sequence,
            challengeNonce: challenge.nonce,
            callEpochNonce: challenge.callEpochNonce,
            state: .preflightArmed
        )
        let message = ControlChannelMessage.macHostedCallEvidence(evidence)

        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["kind"] as? String, "macHostedCallEvidence")

        let encodedEvidence = try XCTUnwrap(
            object["macHostedCallEvidence"] as? [String: Any]
        )
        XCTAssertEqual(encodedEvidence["protocolVersion"] as? Int, 3)
        XCTAssertEqual(encodedEvidence["sequence"] as? Int, 42)
        XCTAssertEqual(encodedEvidence["challengeSequence"] as? Int, 7)
        XCTAssertEqual(
            encodedEvidence["challengeNonce"] as? String,
            challenge.nonce.uuidString
        )
        XCTAssertEqual(
            encodedEvidence["callEpochNonce"] as? String,
            challenge.callEpochNonce.uuidString
        )
        XCTAssertEqual(
            encodedEvidence["state"] as? String,
            "preflightArmed"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            message
        )
    }

    func testEvidenceControlMessageRejectsNonVersionTwoEnvelope() {
        let nonce = UUID().uuidString
        let callEpochNonce = UUID().uuidString
        let data = Data(
            "{\"version\":1,\"kind\":\"macHostedCallEvidence\",\"macHostedCallEvidence\":{\"protocolVersion\":2,\"sequence\":42,\"challengeSequence\":7,\"challengeNonce\":\"\(nonce)\",\"callEpochNonce\":\"\(callEpochNonce)\",\"state\":\"active\"}}".utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data)
        )
    }

    func testViewerEchoesCapabilityOnlyForACompatibleHostOffer() {
        let plainOffer = "v=0\r\ns=-\r\nm=audio 9 RTP/AVP 111\r\n"
        let hostOffer = MacHostedCallEvidenceSDP.advertisingHostSupport(
            in: plainOffer
        )
        let plainAnswer = "v=0\r\ns=-\r\nm=audio 9 RTP/AVP 111\r\n"

        XCTAssertEqual(
            MacHostedCallEvidenceSDP.advertisingViewerSupport(
                in: plainAnswer,
                remoteOfferSDP: plainOffer
            ),
            plainAnswer
        )
        XCTAssertTrue(
            MacHostedCallEvidenceSDP.peerSupportsEvidence(
                in: MacHostedCallEvidenceSDP.advertisingViewerSupport(
                    in: plainAnswer,
                    remoteOfferSDP: hostOffer
                )
            )
        )
    }

    func testChallengeControlMessageRoundTripsInsideStrictVersionTwoEnvelope() throws {
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: 9,
            callEpochNonce: UUID()
        )
        let message = ControlChannelMessage.macHostedCallChallenge(
            challenge
        )
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["kind"] as? String, "macHostedCallChallenge")
        let encodedChallenge = try XCTUnwrap(
            object["macHostedCallChallenge"] as? [String: Any]
        )
        XCTAssertEqual(encodedChallenge["protocolVersion"] as? Int, 3)
        XCTAssertEqual(
            encodedChallenge["callEpochNonce"] as? String,
            challenge.callEpochNonce.uuidString
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ControlChannelMessage.self, from: data),
            message
        )
    }

    func testPriorChallengeAndEvidencePayloadsWithoutCallEpochCannotDecode() {
        let challengeNonce = UUID().uuidString
        let oldChallenge = Data(
            "{\"version\":2,\"kind\":\"macHostedCallChallenge\",\"macHostedCallChallenge\":{\"protocolVersion\":1,\"sequence\":9,\"nonce\":\"\(challengeNonce)\"}}".utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ControlChannelMessage.self,
                from: oldChallenge
            )
        )

        let oldEvidence = Data(
            "{\"version\":2,\"kind\":\"macHostedCallEvidence\",\"macHostedCallEvidence\":{\"protocolVersion\":1,\"sequence\":42,\"challengeSequence\":9,\"challengeNonce\":\"\(challengeNonce)\",\"state\":\"active\"}}".utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ControlChannelMessage.self,
                from: oldEvidence
            )
        )
    }
}
