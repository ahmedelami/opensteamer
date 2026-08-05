import Foundation
@testable import CaptureCore
@testable import CaptureServer
@testable import WebRTCTransport
import XCTest

final class WorldwideMacHostedCallObservationPolicyTests: XCTestCase {
    func testRejectsReorderedObservationEvenWhenChallengeMatches() {
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: 1,
            callEpochNonce: UUID()
        )

        XCTAssertTrue(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 11,
                highestAdmittedSequence: 10,
                observationChallenge: nativeChallenge(challenge),
                currentChallenge: challenge
            )
        )
        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 10,
                highestAdmittedSequence: 11,
                observationChallenge: nativeChallenge(challenge),
                currentChallenge: challenge
            )
        )
    }

    func testRejectsObservationFromPriorChallenge() {
        let callEpochNonce = UUID()
        let prior = WebRTCMacHostedCallChallenge(
            sequence: 1,
            callEpochNonce: callEpochNonce
        )
        let current = WebRTCMacHostedCallChallenge(
            sequence: 2,
            callEpochNonce: callEpochNonce
        )

        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 12,
                highestAdmittedSequence: 11,
                observationChallenge: nativeChallenge(prior),
                currentChallenge: current
            )
        )
        XCTAssertTrue(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 12,
                highestAdmittedSequence: 11,
                observationChallenge: nativeChallenge(current),
                currentChallenge: current
            )
        )
    }

    func testRejectsPriorSequenceWhenNonceIsReused() {
        let nonce = UUID()
        let callEpochNonce = UUID()
        let prior = WebRTCMacHostedCallChallenge(
            sequence: 1,
            callEpochNonce: callEpochNonce,
            nonce: nonce
        )
        let current = WebRTCMacHostedCallChallenge(
            sequence: 2,
            callEpochNonce: callEpochNonce,
            nonce: nonce
        )

        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 12,
                highestAdmittedSequence: 11,
                observationChallenge: nativeChallenge(prior),
                currentChallenge: current
            )
        )
        XCTAssertTrue(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 13,
                highestAdmittedSequence: 11,
                observationChallenge: nativeChallenge(current),
                currentChallenge: current
            )
        )
    }

    func testRejectsWrongCallEpochEvenWhenSequenceAndNonceMatch() {
        let nonce = UUID()
        let current = WebRTCMacHostedCallChallenge(
            sequence: 7,
            callEpochNonce: UUID(),
            nonce: nonce
        )
        let wrongEpochObservation =
            SystemAudioMacFaceTimeActivityChallenge(
                sequence: current.sequence,
                nonce: nonce,
                callEpochNonce: UUID()
            )

        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 1,
                highestAdmittedSequence: 0,
                observationChallenge: wrongEpochObservation,
                currentChallenge: current
            )
        )
    }

    func testRejectsMissingOrInvalidChallenge() {
        let invalid = WebRTCMacHostedCallChallenge(
            sequence: 0,
            callEpochNonce: UUID()
        )

        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 1,
                highestAdmittedSequence: 0,
                observationChallenge: nativeChallenge(invalid),
                currentChallenge: invalid
            )
        )
        XCTAssertFalse(
            WorldwideMacHostedCallObservationPolicy.admits(
                observationSequence: 1,
                highestAdmittedSequence: 0,
                observationChallenge: nil,
                currentChallenge: nil
            )
        )
    }

    private func nativeChallenge(
        _ challenge: WebRTCMacHostedCallChallenge
    ) -> SystemAudioMacFaceTimeActivityChallenge {
        SystemAudioMacFaceTimeActivityChallenge(
            sequence: challenge.sequence,
            nonce: challenge.nonce,
            callEpochNonce: challenge.callEpochNonce
        )
    }
}
