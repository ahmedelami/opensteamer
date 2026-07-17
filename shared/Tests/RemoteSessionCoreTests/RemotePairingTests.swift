import CryptoKit
import Foundation
import Testing
@testable import RemoteSessionCore

struct RemotePairingTests {
    private let invitationSecret = Data(0..<20)
    private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let viewerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func identitiesAreValidatedRoundTrippableAndRedacted() throws {
        let identity = try makeIdentity(role: .host)
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(RemoteDeviceIdentity.self, from: encoded)

        #expect(decoded == identity)
        #expect(decoded.signingPublicKey.count == 32)
        #expect(decoded.description == "<redacted remote device identity>")
        #expect(!decoded.description.contains(identity.deviceID.uuidString))

        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var invalid = object
        invalid["signingPrivateKey"] = Data(repeating: 0, count: 31).base64EncodedString()
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: RemoteSessionCoreError.invalidDeviceIdentity) {
            try JSONDecoder().decode(RemoteDeviceIdentity.self, from: invalidData)
        }
    }

    @Test func pairingRequiresAuthenticatedTranscriptConfirmationAndCommitAcknowledgement() throws {
        let (host, viewer) = try makePairingParticipants()
        let hostAgreement = try host.accept(viewer.hello)
        let viewerAgreement = try viewer.accept(host.hello)

        #expect(hostAgreement.pairID == viewerAgreement.pairID)

        let hostConfirmation = try hostAgreement.makeConfirmation()
        let viewerConfirmation = try viewerAgreement.makeConfirmation()
        try hostAgreement.verify(viewerConfirmation)
        try viewerAgreement.verify(hostConfirmation)

        let proposal = try hostAgreement.makeCommit(phase: .proposal)
        try viewerAgreement.verify(proposal, expectedPhase: .proposal)
        let acknowledgement = try viewerAgreement.makeCommit(phase: .acknowledgement)
        try hostAgreement.verify(acknowledgement, expectedPhase: .acknowledgement)

        var hostRecord = try hostAgreement.finalize(
            peerConfirmation: viewerConfirmation,
            finalPeerCommit: acknowledgement,
            createdAt: createdAt
        )
        let completion = try hostAgreement.makeCommit(phase: .completion)
        try viewerAgreement.verify(completion, expectedPhase: .completion)
        let viewerRecord = try viewerAgreement.finalize(
            peerConfirmation: hostConfirmation,
            finalPeerCommit: completion,
            createdAt: createdAt
        )

        #expect(hostRecord.pairID == viewerRecord.pairID)
        #expect(hostRecord.localRole == .host)
        #expect(hostRecord.remoteRole == .viewer)
        #expect(viewerRecord.localRole == .viewer)
        #expect(viewerRecord.remoteRole == .host)
        #expect(hostRecord.pairingState == .acceptedReceived)
        #expect(viewerRecord.pairingState == .active)
        let preparedCompletion = try hostRecord.prepareCompletion(
            using: makeIdentity(role: .host)
        )
        #expect(preparedCompletion.commitID == completion.commitID)
        #expect(hostRecord.recoveryAction == .resend(preparedCompletion))
        try hostRecord.markCompletionSent(commitID: preparedCompletion.commitID)
        let activation: RemotePairingCommit
        if case .resend(let commit) = viewerRecord.recoveryAction {
            activation = commit
        } else {
            Issue.record("Viewer did not retain its activation acknowledgement")
            return
        }
        try hostRecord.acceptActivationAcknowledgement(activation)
        #expect(hostRecord.pairingState == .active)
        let exchangeID = try RemoteAvailabilityExchangeID(rawValue: Data(0..<16))
        let hostLocator = try hostRecord.availabilityLocator()
        let viewerLocator = try viewerRecord.availabilityLocator()
        #expect(hostLocator.channelID == viewerLocator.channelID)
        #expect(hostLocator.admissionProof != viewerLocator.admissionProof)
        #expect(hostLocator.viewerRegistrationProof == viewerLocator.admissionProof)
        #expect(viewerLocator.viewerRegistrationProof == nil)
        let hostCredential = try hostRecord.availabilityCredential(exchangeID: exchangeID)
        let viewerCredential = try viewerRecord.availabilityCredential(exchangeID: exchangeID)
        #expect(hostCredential != viewerCredential)
        let availabilityEnvelope = try RemoteAvailabilityCipher(
            credential: viewerCredential,
            exchangeID: exchangeID,
            role: .viewer
        ).seal(.pairingCommit(activation), sequence: 0)
        #expect(
            try RemoteAvailabilityCipher(
                credential: hostCredential,
                exchangeID: exchangeID,
                role: .host
            ).open(availabilityEnvelope) == .pairingCommit(activation)
        )
        #expect(hostRecord.description == "<redacted paired remote device>")

        #expect(throws: RemoteSessionCoreError.invalidPairingCommit) {
            try viewerAgreement.finalize(
                peerConfirmation: hostConfirmation,
                finalPeerCommit: proposal,
                createdAt: createdAt
            )
        }
    }

    @Test func wrongInvitationRoleSubstitutionAndSignatureTamperingAreRejected() throws {
        let hostIdentity = try makeIdentity(role: .host)
        let viewerIdentity = try makeIdentity(role: .viewer)
        let hostInvitation = try RemoteInvitationCode(secret: invitationSecret)
        let wrongInvitation = try RemoteInvitationCode(secret: Data(repeating: 0xFF, count: 20))
        let host = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: hostInvitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x31, count: 32),
            nonce: Data(repeating: 0x41, count: 32)
        )
        let wrongViewer = try RemotePairingParticipant(
            identity: viewerIdentity,
            invitation: wrongInvitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x32, count: 32),
            nonce: Data(repeating: 0x42, count: 32)
        )

        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try host.accept(wrongViewer.hello)
        }

        let viewer = try RemotePairingParticipant(
            identity: viewerIdentity,
            invitation: hostInvitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x32, count: 32),
            nonce: Data(repeating: 0x42, count: 32)
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(viewer.hello)
        ) as! [String: Any]
        var tampered = object
        var signature = try #require(Data(base64Encoded: object["signature"] as! String))
        signature[0] ^= 1
        tampered["signature"] = signature.base64EncodedString()
        let tamperedHello = try JSONDecoder().decode(
            RemotePairingHello.self,
            from: JSONSerialization.data(withJSONObject: tampered)
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try host.accept(tamperedHello)
        }

        let reflectedHost = try RemotePairingParticipant(
            identity: makeIdentity(role: .host),
            invitation: hostInvitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x33, count: 32),
            nonce: Data(repeating: 0x43, count: 32)
        )
        #expect(throws: RemoteSessionCoreError.pairingRoleConflict) {
            try host.accept(reflectedHost.hello)
        }
    }

    @Test func zeroX25519SharedSecretsAreRejectedInPairingAndReconnect() throws {
        let invitation = try RemoteInvitationCode(secret: invitationSecret)
        let host = try RemotePairingParticipant(
            identity: makeIdentity(role: .host),
            invitation: invitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x31, count: 32),
            nonce: Data(repeating: 0x41, count: 32)
        )
        let viewerIdentity = try makeIdentity(role: .viewer)
        let unsignedHello = RemotePairingHelloUnsigned(
            protocolVersion: RemotePairingHello.currentProtocolVersion,
            deviceID: viewerIdentity.deviceID,
            role: .viewer,
            displayName: viewerIdentity.displayName,
            signingPublicKey: viewerIdentity.signingPublicKey,
            ephemeralKeyAgreementPublicKey: Data(repeating: 0, count: 32),
            nonce: Data(repeating: 0x42, count: 32)
        )
        let canonicalHello = try remoteCanonicalData(unsignedHello)
        let tag = remoteHMAC(
            key: invitation.secretMaterial,
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Hello.PSK.v1",
                canonicalHello
            )
        )
        let zeroHello = RemotePairingHello(
            deviceID: unsignedHello.deviceID,
            role: unsignedHello.role,
            displayName: unsignedHello.displayName,
            signingPublicKey: unsignedHello.signingPublicKey,
            ephemeralKeyAgreementPublicKey: unsignedHello.ephemeralKeyAgreementPublicKey,
            nonce: unsignedHello.nonce,
            authenticationTag: tag,
            signature: try viewerIdentity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Hello.Signature.v1",
                    canonicalHello,
                    tag
                )
            )
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try host.accept(zeroHello)
        }

        var records = try makePairedRecords()
        let unsignedRequest = RemoteReconnectRequestUnsigned(
            protocolVersion: RemoteReconnectRequest.currentProtocolVersion,
            pairID: records.viewer.pairID,
            requesterDeviceID: records.viewer.localDeviceID,
            requesterRole: .viewer,
            targetDeviceID: records.viewer.remoteDeviceID,
            sequence: 1,
            ephemeralKeyAgreementPublicKey: Data(repeating: 0, count: 32),
            nonce: Data(repeating: 0x55, count: 32)
        )
        let canonicalRequest = try remoteCanonicalData(unsignedRequest)
        let zeroRequest = RemoteReconnectRequest(
            protocolVersion: unsignedRequest.protocolVersion,
            pairID: unsignedRequest.pairID,
            requesterDeviceID: unsignedRequest.requesterDeviceID,
            requesterRole: unsignedRequest.requesterRole,
            targetDeviceID: unsignedRequest.targetDeviceID,
            sequence: unsignedRequest.sequence,
            ephemeralKeyAgreementPublicKey: unsignedRequest.ephemeralKeyAgreementPublicKey,
            nonce: unsignedRequest.nonce,
            signature: try viewerIdentity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Reconnect.Request.Signature.v1",
                    canonicalRequest
                )
            )
        )
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try records.host.respond(
                to: zeroRequest,
                using: makeIdentity(role: .host),
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x52, count: 32),
                nonce: Data(repeating: 0x62, count: 32)
            )
        }
    }

    @Test func pairingCommitRecoveryIsCrashSafeAndIdempotent() throws {
        let (host, viewer) = try makePairingParticipants()
        let hostAgreement = try host.accept(viewer.hello)
        let viewerAgreement = try viewer.accept(host.hello)
        let hostConfirmation = try hostAgreement.makeConfirmation()
        let viewerConfirmation = try viewerAgreement.makeConfirmation()
        var hostRecord = try hostAgreement.makePendingRecord(
            peerConfirmation: viewerConfirmation,
            createdAt: createdAt
        )
        var viewerRecord = try viewerAgreement.makePendingRecord(
            peerConfirmation: hostConfirmation,
            createdAt: createdAt
        )
        #expect(hostRecord.recoveryAction == .issueProposal)
        #expect(viewerRecord.recoveryAction == .awaitProposal)
        _ = try hostRecord.availabilityLocator()
        _ = try viewerRecord.availabilityLocator()
        #expect(throws: RemoteSessionCoreError.invalidPairingCommit) {
            try viewerRecord.beginReconnect(
                using: makeIdentity(role: .viewer),
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x51, count: 32),
                nonce: Data(repeating: 0x61, count: 32)
            )
        }

        let proposal = try hostRecord.prepareProposal(using: makeIdentity(role: .host))
        hostRecord = try roundTrip(hostRecord)
        #expect(try hostRecord.prepareProposal(using: makeIdentity(role: .host)) == proposal)

        let acknowledgement = try viewerRecord.prepareAcknowledgement(
            after: proposal,
            using: makeIdentity(role: .viewer)
        )
        viewerRecord = try roundTrip(viewerRecord)
        #expect(
            try viewerRecord.prepareAcknowledgement(
                after: proposal,
                using: makeIdentity(role: .viewer)
            ) == acknowledgement
        )

        try hostRecord.acceptAcknowledgement(acknowledgement)
        try hostRecord.acceptAcknowledgement(acknowledgement)
        #expect(hostRecord.pairingState == .acceptedReceived)
        let completion = try hostRecord.prepareCompletion(using: makeIdentity(role: .host))
        hostRecord = try roundTrip(hostRecord)
        #expect(try hostRecord.prepareCompletion(using: makeIdentity(role: .host)) == completion)
        try hostRecord.markCompletionSent(commitID: completion.commitID)
        try hostRecord.markCompletionSent(commitID: completion.commitID)
        // Simulate completion delivery loss plus both processes relaunching. Availability is
        // still available to the viewer's accepted-issued state, and the active host retained
        // the exact completion needed to converge.
        hostRecord = try roundTrip(hostRecord)
        viewerRecord = try roundTrip(viewerRecord)
        #expect(hostRecord.pairingState == .acceptedReceived)
        #expect(viewerRecord.pairingState == .acceptedIssued)
        _ = try viewerRecord.availabilityLocator()
        try hostRecord.acceptAcknowledgement(acknowledgement)
        #expect(try hostRecord.prepareCompletion(using: makeIdentity(role: .host)) == completion)
        let activation = try viewerRecord.acceptCompletion(
            completion,
            using: makeIdentity(role: .viewer)
        )
        let replayedActivation = try viewerRecord.acceptCompletion(
            completion,
            using: makeIdentity(role: .viewer)
        )
        #expect(activation == replayedActivation)
        try hostRecord.acceptActivationAcknowledgement(activation)
        try hostRecord.acceptActivationAcknowledgement(activation)
        #expect(hostRecord.pairingState == .active)
        #expect(viewerRecord.pairingState == .active)

        // A delayed authenticated ACK must not reopen durable host recovery or corrupt an active
        // record. The host can deterministically replay completion and remain active throughout.
        try hostRecord.acceptAcknowledgement(acknowledgement)
        let replayedCompletion = try hostRecord.prepareCompletion(
            using: makeIdentity(role: .host)
        )
        #expect(replayedCompletion.phase == .completion)
        #expect(replayedCompletion.commitID == completion.commitID)
        #expect(hostRecord.recoveryAction == .none)
        try hostRecord.markCompletionSent(commitID: replayedCompletion.commitID)
        hostRecord = try roundTrip(hostRecord)
        #expect(hostRecord.pairingState == .active)
        #expect(hostRecord.recoveryAction == .none)
        let finalActivationReplay = try viewerRecord.acceptCompletion(
            replayedCompletion,
            using: makeIdentity(role: .viewer)
        )
        try hostRecord.acceptActivationAcknowledgement(finalActivationReplay)
        #expect(hostRecord.pairingState == .active)
    }

    @Test func pairedRecordRoundTripsWithCountersButNeverPrintsSecrets() throws {
        let records = try makePairedRecords()
        var viewerRecord = records.viewer
        let initiator = try viewerRecord.beginReconnect(
            using: try makeIdentity(role: .viewer),
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x51, count: 32),
            nonce: Data(repeating: 0x61, count: 32)
        )
        #expect(initiator.request.sequence == 1)
        #expect(viewerRecord.nextOutboundReconnectSequence == 2)

        let encoded = try JSONEncoder().encode(viewerRecord)
        let decoded = try JSONDecoder().decode(RemotePairedDeviceRecord.self, from: encoded)
        #expect(decoded == viewerRecord)
        #expect(decoded.description == "<redacted paired remote device>")
        #expect(!decoded.description.contains(decoded.pairID.uuidString))

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["pairRootKey"] = Data(repeating: 0, count: 31).base64EncodedString()
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RemoteSessionCoreError.invalidPairedDeviceRecord) {
            try JSONDecoder().decode(RemotePairedDeviceRecord.self, from: invalid)
        }

        let exchangeID = try RemoteAvailabilityExchangeID(rawValue: Data(0..<16))
        let locator = try decoded.availabilityLocator()
        let credential = try locator.credential(exchangeID: exchangeID)
        for text in [
            decoded.description,
            locator.description,
            credential.description,
            exchangeID.description
        ] {
            #expect(text.contains("redacted"))
            #expect(!text.contains(decoded.pairID.uuidString))
        }
    }

    @Test func pairedRecordDecoderRejectsInconsistentOrForgedRecoveryState() throws {
        let viewer = try makePairedRecords().viewer
        let encoded = try JSONEncoder().encode(viewer)
        let original = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        var missingRecovery = original
        missingRecovery.removeValue(forKey: "recoveryCommit")
        #expect(throws: RemoteSessionCoreError.invalidPairedDeviceRecord) {
            try JSONDecoder().decode(
                RemotePairedDeviceRecord.self,
                from: JSONSerialization.data(withJSONObject: missingRecovery)
            )
        }

        var wrongState = original
        wrongState["pairingState"] = "acceptedIssued"
        #expect(throws: RemoteSessionCoreError.invalidPairedDeviceRecord) {
            try JSONDecoder().decode(
                RemotePairedDeviceRecord.self,
                from: JSONSerialization.data(withJSONObject: wrongState)
            )
        }

        var forged = original
        var recovery = try #require(forged["recoveryCommit"] as? [String: Any])
        recovery["phase"] = "acknowledgement"
        forged["pairingState"] = "acceptedIssued"
        forged["recoveryCommit"] = recovery
        #expect(throws: RemoteSessionCoreError.invalidPairedDeviceRecord) {
            try JSONDecoder().decode(
                RemotePairedDeviceRecord.self,
                from: JSONSerialization.data(withJSONObject: forged)
            )
        }
    }

    @Test func reconnectIsSignedMonotonicAndDerivesFreshMatchingSessionCredentials() throws {
        let first = try makeReconnect(sequenceOffset: 0, nonceByte: 0x71)
        #expect(first.hostCredential == first.viewerCredential)

        let hostCipher = RemoteSignalingCipher(credential: first.hostCredential, role: .host)
        let viewerCipher = RemoteSignalingCipher(credential: first.viewerCredential, role: .viewer)
        let envelope = try hostCipher.seal(.control(.showScreen), sequence: 0)
        #expect(try viewerCipher.open(envelope) == .control(.showScreen))

        let second = try makeReconnect(sequenceOffset: 1, nonceByte: 0x72)
        #expect(first.hostCredential.channelID != second.hostCredential.channelID)
        #expect(first.hostCredential != second.hostCredential)
    }

    @Test func reconnectRejectsReplayWrongIdentityAndTampering() throws {
        var records = try makePairedRecords()
        let viewerIdentity = try makeIdentity(role: .viewer)
        let hostIdentity = try makeIdentity(role: .host)
        let initiator = try records.viewer.beginReconnect(
            using: viewerIdentity,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x51, count: 32),
            nonce: Data(repeating: 0x61, count: 32)
        )
        let pristineHostRecord = records.host
        _ = try records.host.respond(
            to: initiator.request,
            using: hostIdentity,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x52, count: 32),
            nonce: Data(repeating: 0x62, count: 32)
        )

        #expect(throws: RemoteSessionCoreError.staleReconnectSequence) {
            try records.host.respond(
                to: initiator.request,
                using: hostIdentity,
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x53, count: 32),
                nonce: Data(repeating: 0x63, count: 32)
            )
        }

        let wrongHost = try RemoteDeviceIdentity(
            deviceID: hostID,
            role: .host,
            displayName: "Impostor",
            signingPrivateKeyRawRepresentation: Data(repeating: 0x99, count: 32)
        )
        var freshHostRecord = pristineHostRecord
        #expect(throws: RemoteSessionCoreError.deviceIdentityMismatch) {
            try freshHostRecord.respond(
                to: initiator.request,
                using: wrongHost,
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x53, count: 32),
                nonce: Data(repeating: 0x63, count: 32)
            )
        }

        let data = try JSONEncoder().encode(initiator.request)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var signature = try #require(Data(base64Encoded: object["signature"] as! String))
        signature[0] ^= 1
        object["signature"] = signature.base64EncodedString()
        let tampered = try JSONDecoder().decode(
            RemoteReconnectRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        freshHostRecord = pristineHostRecord
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try freshHostRecord.respond(
                to: tampered,
                using: hostIdentity,
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x53, count: 32),
                nonce: Data(repeating: 0x63, count: 32)
            )
        }
    }

    private func makeIdentity(role: RemotePeerRole) throws -> RemoteDeviceIdentity {
        try RemoteDeviceIdentity(
            deviceID: role == .host ? hostID : viewerID,
            role: role,
            displayName: role == .host ? "Mac mini" : "Test iPhone",
            signingPrivateKeyRawRepresentation: Data(repeating: role == .host ? 0x11 : 0x22, count: 32)
        )
    }

    private func makePairingParticipants() throws -> (
        host: RemotePairingParticipant,
        viewer: RemotePairingParticipant
    ) {
        let invitation = try RemoteInvitationCode(secret: invitationSecret)
        return (
            try RemotePairingParticipant(
                identity: makeIdentity(role: .host),
                invitation: invitation,
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x31, count: 32),
                nonce: Data(repeating: 0x41, count: 32)
            ),
            try RemotePairingParticipant(
                identity: makeIdentity(role: .viewer),
                invitation: invitation,
                ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x32, count: 32),
                nonce: Data(repeating: 0x42, count: 32)
            )
        )
    }

    private func makePairedRecords() throws -> (
        host: RemotePairedDeviceRecord,
        viewer: RemotePairedDeviceRecord
    ) {
        let (host, viewer) = try makePairingParticipants()
        let hostAgreement = try host.accept(viewer.hello)
        let viewerAgreement = try viewer.accept(host.hello)
        let hostConfirmation = try hostAgreement.makeConfirmation()
        let viewerConfirmation = try viewerAgreement.makeConfirmation()
        let acknowledgement = try viewerAgreement.makeCommit(phase: .acknowledgement)
        let completion = try hostAgreement.makeCommit(phase: .completion)
        var hostRecord = try hostAgreement.finalize(
                peerConfirmation: viewerConfirmation,
                finalPeerCommit: acknowledgement,
                createdAt: createdAt
            )
        let persistedCompletion = try hostRecord.prepareCompletion(
            using: makeIdentity(role: .host)
        )
        try hostRecord.markCompletionSent(commitID: persistedCompletion.commitID)
        let viewerRecord = try viewerAgreement.finalize(
            peerConfirmation: hostConfirmation,
            finalPeerCommit: completion,
            createdAt: createdAt
        )
        guard case .resend(let activation) = viewerRecord.recoveryAction else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try hostRecord.acceptActivationAcknowledgement(activation)
        return (
            hostRecord,
            viewerRecord
        )
    }

    private func makeReconnect(
        sequenceOffset: UInt64,
        nonceByte: UInt8
    ) throws -> (
        hostCredential: RemoteRendezvousCredential,
        viewerCredential: RemoteRendezvousCredential
    ) {
        var records = try makePairedRecords()
        records.viewer.nextOutboundReconnectSequence += sequenceOffset
        let initiator = try records.viewer.beginReconnect(
            using: makeIdentity(role: .viewer),
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x51 &+ UInt8(sequenceOffset), count: 32),
            nonce: Data(repeating: nonceByte, count: 32)
        )
        let responder = try records.host.respond(
            to: initiator.request,
            using: makeIdentity(role: .host),
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x52 &+ UInt8(sequenceOffset), count: 32),
            nonce: Data(repeating: nonceByte &+ 1, count: 32)
        )
        return (
            responder.credential,
            try initiator.complete(with: responder.response)
        )
    }

    private func roundTrip(_ record: RemotePairedDeviceRecord) throws -> RemotePairedDeviceRecord {
        try JSONDecoder().decode(
            RemotePairedDeviceRecord.self,
            from: JSONEncoder().encode(record)
        )
    }
}
