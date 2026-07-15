import Foundation
import Testing
@testable import RemoteSessionCore

struct RemoteSignalingCryptoTests {
    private func invitation(byte: UInt8) throws -> RemoteInvitationCode {
        try RemoteInvitationCode(secret: Data(repeating: byte, count: 20))
    }

    @Test func bothRolesDeriveOneChannelAndOppositeDirections() throws {
        let code = try invitation(byte: 1)
        let host = RemoteSignalingCipher(invitation: code, role: .host)
        let viewer = RemoteSignalingCipher(invitation: code, role: .viewer)

        #expect(host.channelID == viewer.channelID)
        #expect(host.admissionProof == viewer.admissionProof)
        #expect(host.admissionProof.wireValue.utf8.count == 43)
        #expect(host.admissionProof.description == "<redacted rendezvous admission proof>")
        #expect(host.sendingDirection == .hostToViewer)
        #expect(host.receivingDirection == .viewerToHost)
        #expect(viewer.sendingDirection == .viewerToHost)
        #expect(viewer.receivingDirection == .hostToViewer)
        #expect(host.channelID.wireValue.count == 52)
        #expect(host.channelID.description == "<redacted rendezvous channel>")
    }

    @Test func independentInvitationsDeriveIndependentChannels() throws {
        let first = RemoteSignalingCipher(invitation: try invitation(byte: 1), role: .host)
        let second = RemoteSignalingCipher(invitation: try invitation(byte: 2), role: .host)
        #expect(first.channelID != second.channelID)
        #expect(first.admissionProof != second.admissionProof)
    }

    @Test func signalingRoundTripsInBothDirections() throws {
        let code = try invitation(byte: 3)
        let host = RemoteSignalingCipher(invitation: code, role: .host)
        let viewer = RemoteSignalingCipher(invitation: code, role: .viewer)

        let offer = RemoteSignalPayload.offer(sdp: "v=0\r\na=fingerprint:sha-256 00:11\r\n")
        let offerEnvelope = try host.seal(offer, sequence: 42)
        #expect(try viewer.open(offerEnvelope) == offer)

        let answer = RemoteSignalPayload.answer(sdp: "v=0\r\na=setup:active\r\n")
        let answerEnvelope = try viewer.seal(answer, sequence: 7)
        #expect(try host.open(answerEnvelope) == answer)
    }

    @Test func ciphertextAndAuthenticatedHeadersRejectTampering() throws {
        let code = try invitation(byte: 4)
        let host = RemoteSignalingCipher(invitation: code, role: .host)
        let viewer = RemoteSignalingCipher(invitation: code, role: .viewer)
        let original = try host.seal(.control(.showScreen), sequence: 9)

        var changedCiphertext = original.ciphertext
        changedCiphertext[changedCiphertext.index(before: changedCiphertext.endIndex)] ^= 1
        let ciphertextTamper = SealedSignalingEnvelope(
            channelID: original.channelID,
            direction: original.direction,
            sequence: original.sequence,
            ciphertext: changedCiphertext
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try viewer.open(ciphertextTamper)
        }

        let sequenceTamper = SealedSignalingEnvelope(
            channelID: original.channelID,
            direction: original.direction,
            sequence: original.sequence + 1,
            ciphertext: original.ciphertext
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try viewer.open(sequenceTamper)
        }

        let versionTamper = SealedSignalingEnvelope(
            version: 2,
            channelID: original.channelID,
            direction: original.direction,
            sequence: original.sequence,
            ciphertext: original.ciphertext
        )
        #expect(throws: RemoteSessionCoreError.unsupportedEnvelopeVersion) {
            try viewer.open(versionTamper)
        }
    }

    @Test func wrongCodeCannotOpenEnvelope() throws {
        let host = RemoteSignalingCipher(invitation: try invitation(byte: 5), role: .host)
        let wrongViewer = RemoteSignalingCipher(invitation: try invitation(byte: 6), role: .viewer)
        let envelope = try host.seal(.control(.hideScreen), sequence: 0)

        #expect(throws: RemoteSessionCoreError.wrongRendezvousChannel) {
            try wrongViewer.open(envelope)
        }
    }

    @Test func reflectionAndDirectionSubstitutionFail() throws {
        let code = try invitation(byte: 7)
        let host = RemoteSignalingCipher(invitation: code, role: .host)
        let envelope = try host.seal(.control(.requestKeyFrame), sequence: 3)

        // A sender must not accept its own outbound traffic as inbound traffic.
        #expect(throws: RemoteSessionCoreError.unexpectedSignalDirection) {
            try host.open(envelope)
        }

        // Relabeling the packet as inbound passes the direction check but fails AEAD because
        // each direction has a separate HKDF key and the direction is also authenticated.
        let reflected = SealedSignalingEnvelope(
            channelID: envelope.channelID,
            direction: .viewerToHost,
            sequence: envelope.sequence,
            ciphertext: envelope.ciphertext
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try host.open(reflected)
        }
    }

    @Test func receiverRejectsReplayAfterAuthentication() async throws {
        let code = try invitation(byte: 8)
        let sender = RemoteSignalingCipher(invitation: code, role: .host)
        let receiver = RemoteSignalingReceiver(
            cipher: RemoteSignalingCipher(invitation: code, role: .viewer)
        )
        let envelope = try sender.seal(.control(.showScreen), sequence: 12)

        #expect(try await receiver.open(envelope) == .control(.showScreen))
        do {
            _ = try await receiver.open(envelope)
            Issue.record("A replayed envelope was accepted")
        } catch let error as RemoteSessionCoreError {
            #expect(error == .replayedSequence)
        }
    }

    @Test func replayWindowAllowsReorderingAndRejectsDuplicatesAndOldPackets() throws {
        var guardState = SignalingReplayGuard()
        try guardState.accept(sequence: 10)
        try guardState.accept(sequence: 8)
        try guardState.accept(sequence: 9)

        #expect(throws: RemoteSessionCoreError.replayedSequence) {
            try guardState.accept(sequence: 8)
        }

        try guardState.accept(sequence: 100)
        #expect(throws: RemoteSessionCoreError.sequenceOutsideReplayWindow) {
            try guardState.accept(sequence: 36)
        }
    }

    @Test func senderAllocatesUniqueMonotonicSequences() async throws {
        let cipher = RemoteSignalingCipher(invitation: try invitation(byte: 9), role: .host)
        let sender = RemoteSignalingSender(cipher: cipher, initialSequence: 99)
        let first = try await sender.seal(.control(.showScreen))
        let second = try await sender.seal(.control(.hideScreen))
        #expect(first.sequence == 99)
        #expect(second.sequence == 100)
    }
}
