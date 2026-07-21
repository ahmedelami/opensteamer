import CryptoKit
import Foundation

// Compatibility ABI: the pre-rebrand `AudioStreamer.*` labels below authenticate the v1 pairing
// transcript. Their exact bytes must remain stable for already-issued invitations and paired apps.

/// A signed, invitation-authenticated introduction carrying one ephemeral agreement key.
public struct RemotePairingHello: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let deviceID: UUID
    public let role: RemotePeerRole
    public let displayName: String?
    public let signingPublicKey: Data
    public let ephemeralKeyAgreementPublicKey: Data
    public let nonce: Data
    public let authenticationTag: Data
    public let signature: Data

    internal init(
        protocolVersion: UInt8 = RemotePairingHello.currentProtocolVersion,
        deviceID: UUID,
        role: RemotePeerRole,
        displayName: String?,
        signingPublicKey: Data,
        ephemeralKeyAgreementPublicKey: Data,
        nonce: Data,
        authenticationTag: Data,
        signature: Data
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.role = role
        self.displayName = displayName
        self.signingPublicKey = signingPublicKey
        self.ephemeralKeyAgreementPublicKey = ephemeralKeyAgreementPublicKey
        self.nonce = nonce
        self.authenticationTag = authenticationTag
        self.signature = signature
    }

    internal var unsigned: RemotePairingHelloUnsigned {
        RemotePairingHelloUnsigned(
            protocolVersion: protocolVersion,
            deviceID: deviceID,
            role: role,
            displayName: displayName,
            signingPublicKey: signingPublicKey,
            ephemeralKeyAgreementPublicKey: ephemeralKeyAgreementPublicKey,
            nonce: nonce
        )
    }

    internal var isStructurallyValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && !remoteUUIDIsZero(deviceID)
            && remoteValidDisplayName(displayName)
            && signingPublicKey.count == 32
            && ephemeralKeyAgreementPublicKey.count == 32
            && nonce.count == 32
            && authenticationTag.count == 32
            && signature.count == 64
    }
}

/// A signed proof that a peer derived the same pairing transcript and pair root.
public struct RemotePairingConfirmation: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let pairID: UUID
    public let senderDeviceID: UUID
    public let senderRole: RemotePeerRole
    public let recipientDeviceID: UUID
    public let transcriptHash: Data
    public let confirmationTag: Data
    public let signature: Data

    internal var unsigned: RemotePairingConfirmationUnsigned {
        RemotePairingConfirmationUnsigned(
            protocolVersion: protocolVersion,
            pairID: pairID,
            senderDeviceID: senderDeviceID,
            senderRole: senderRole,
            recipientDeviceID: recipientDeviceID,
            transcriptHash: transcriptHash
        )
    }

    internal var isStructurallyValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && !remoteUUIDIsZero(pairID)
            && !remoteUUIDIsZero(senderDeviceID)
            && !remoteUUIDIsZero(recipientDeviceID)
            && senderDeviceID != recipientDeviceID
            && transcriptHash.count == 32
            && confirmationTag.count == 32
            && signature.count == 64
    }
}

/// Persist-before-send phases that make the durable pairing commit recoverable after interruption.
public enum RemotePairingCommitPhase: String, Codable, CaseIterable, Sendable {
    /// Host proposes committing after both transcript confirmations have verified.
    case proposal
    /// Viewer acknowledges the proposal; the host may now persist the pair.
    case acknowledgement
    /// Host confirms receipt; the viewer may now persist the pair.
    case completion
    /// Viewer proves durable completion receipt; only then may the host become active.
    case activationAcknowledgement
}

/// A signed, transcript-bound message advancing the durable pairing state machine.
public struct RemotePairingCommit: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let pairID: UUID
    public let commitID: UUID
    public let senderDeviceID: UUID
    public let senderRole: RemotePeerRole
    public let recipientDeviceID: UUID
    public let transcriptHash: Data
    public let phase: RemotePairingCommitPhase
    public let commitTag: Data
    public let signature: Data

    internal var unsigned: RemotePairingCommitUnsigned {
        RemotePairingCommitUnsigned(
            protocolVersion: protocolVersion,
            pairID: pairID,
            commitID: commitID,
            senderDeviceID: senderDeviceID,
            senderRole: senderRole,
            recipientDeviceID: recipientDeviceID,
            transcriptHash: transcriptHash,
            phase: phase
        )
    }

    internal var isStructurallyValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && !remoteUUIDIsZero(pairID)
            && !remoteUUIDIsZero(commitID)
            && !remoteUUIDIsZero(senderDeviceID)
            && !remoteUUIDIsZero(recipientDeviceID)
            && senderDeviceID != recipientDeviceID
            && transcriptHash.count == 32
            && commitTag.count == 32
            && signature.count == 64
    }
}

/// Holds only the ephemeral bootstrap state needed while a one-time invitation is active.
/// Discard this value after the three-way pairing commit completes.
public struct RemotePairingParticipant: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let hello: RemotePairingHello

    private let identity: RemoteDeviceIdentity
    private let invitation: RemoteInvitationCode
    private let ephemeralPrivateKey: Data

    public init(
        identity: RemoteDeviceIdentity,
        invitation: RemoteInvitationCode
    ) throws {
        try self.init(
            identity: identity,
            invitation: invitation,
            ephemeralPrivateKeyRawRepresentation: Curve25519.KeyAgreement.PrivateKey()
                .rawRepresentation,
            nonce: remoteRandomBytes(count: 32)
        )
    }

    internal init(
        identity: RemoteDeviceIdentity,
        invitation: RemoteInvitationCode,
        ephemeralPrivateKeyRawRepresentation: Data,
        nonce: Data
    ) throws {
        guard identity.version == RemoteDeviceIdentity.currentVersion,
              ephemeralPrivateKeyRawRepresentation.count == 32,
              nonce.count == 32 else {
            throw RemoteSessionCoreError.invalidPairingMessage
        }

        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        do {
            ephemeral = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKeyRawRepresentation
            )
        } catch {
            throw RemoteSessionCoreError.invalidPairingMessage
        }

        let unsigned = RemotePairingHelloUnsigned(
            protocolVersion: RemotePairingHello.currentProtocolVersion,
            deviceID: identity.deviceID,
            role: identity.role,
            displayName: identity.displayName,
            signingPublicKey: identity.signingPublicKey,
            ephemeralKeyAgreementPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce
        )
        let canonical = try remoteCanonicalData(unsigned)
        let authenticationTag = remoteHMAC(
            key: invitation.secretMaterial,
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Hello.PSK.v1",
                canonical
            )
        )
        let signatureInput = remoteDomainSeparated(
            "AudioStreamer.Pairing.Hello.Signature.v1",
            canonical,
            authenticationTag
        )

        self.identity = identity
        self.invitation = invitation
        ephemeralPrivateKey = ephemeralPrivateKeyRawRepresentation
        hello = RemotePairingHello(
            deviceID: identity.deviceID,
            role: identity.role,
            displayName: identity.displayName,
            signingPublicKey: identity.signingPublicKey,
            ephemeralKeyAgreementPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            authenticationTag: authenticationTag,
            signature: try identity.signature(for: signatureInput)
        )
    }

    public var description: String { "<redacted remote pairing participant>" }
    public var debugDescription: String { description }

    /// Verifies the peer hello and derives an agreement bound to both roles and identities.
    public func accept(_ peerHello: RemotePairingHello) throws -> RemotePairingAgreement {
        guard peerHello.protocolVersion == RemotePairingHello.currentProtocolVersion else {
            throw RemoteSessionCoreError.unsupportedPairingVersion
        }
        guard peerHello.isStructurallyValid else {
            throw RemoteSessionCoreError.invalidPairingMessage
        }
        guard peerHello.role != identity.role,
              peerHello.deviceID != identity.deviceID else {
            throw RemoteSessionCoreError.pairingRoleConflict
        }

        let peerCanonical = try remoteCanonicalData(peerHello.unsigned)
        let expectedAuthenticationTag = remoteHMAC(
            key: invitation.secretMaterial,
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Hello.PSK.v1",
                peerCanonical
            )
        )
        guard remoteConstantTimeEqual(
            peerHello.authenticationTag,
            expectedAuthenticationTag
        ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
        guard remoteVerifySignature(
            peerHello.signature,
            for: remoteDomainSeparated(
                "AudioStreamer.Pairing.Hello.Signature.v1",
                peerCanonical,
                peerHello.authenticationTag
            ),
            publicKey: peerHello.signingPublicKey
        ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }

        let localPrivate: Curve25519.KeyAgreement.PrivateKey
        let peerPublic: Curve25519.KeyAgreement.PublicKey
        do {
            localPrivate = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKey
            )
            peerPublic = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerHello.ephemeralKeyAgreementPublicKey
            )
        } catch {
            throw RemoteSessionCoreError.invalidPairingMessage
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try localPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
        let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
        guard sharedData.count == 32, !remoteIsAllZero(sharedData) else {
            throw RemoteSessionCoreError.authenticationFailed
        }

        let hostHello = identity.role == .host ? hello : peerHello
        let viewerHello = identity.role == .viewer ? hello : peerHello
        let transcript = RemotePairingTranscript(host: hostHello, viewer: viewerHello)
        let transcriptHash = remoteSHA256(
            remoteDomainSeparated(
                "AudioStreamer.Pairing.Transcript.v1",
                try remoteCanonicalData(transcript)
            )
        )
        var input = Data()
        input.append(invitation.secretMaterial)
        input.append(sharedData)
        let pairRoot = remoteHKDF(
            input: input,
            salt: transcriptHash,
            label: "AudioStreamer.Pairing.Root.v1"
        )
        let pairID = remoteUUID(
            from: remoteHKDF(
                input: pairRoot,
                salt: transcriptHash,
                label: "AudioStreamer.Pairing.ID.v1"
            )
        )
        let commitID = remoteUUID(
            from: remoteHKDF(
                input: pairRoot,
                salt: transcriptHash,
                label: "AudioStreamer.Pairing.CommitID.v1"
            )
        )

        return RemotePairingAgreement(
            localIdentity: identity,
            peerHello: peerHello,
            pairID: pairID,
            commitID: commitID,
            transcriptHash: transcriptHash,
            pairRoot: pairRoot
        )
    }
}

/// Cryptographically authenticated result of accepting the peer's pairing hello.
/// A durable record is intentionally unavailable until confirmation and the appropriate
/// peer commit phase are supplied to `finalize`.
public struct RemotePairingAgreement: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let pairID: UUID
    public let commitID: UUID
    public let peerDeviceID: UUID
    public let peerRole: RemotePeerRole
    public let peerDisplayName: String?

    private let localIdentity: RemoteDeviceIdentity
    private let peerHello: RemotePairingHello
    private let transcriptHash: Data
    private let pairRoot: Data

    internal init(
        localIdentity: RemoteDeviceIdentity,
        peerHello: RemotePairingHello,
        pairID: UUID,
        commitID: UUID,
        transcriptHash: Data,
        pairRoot: Data
    ) {
        self.localIdentity = localIdentity
        self.peerHello = peerHello
        self.pairID = pairID
        self.commitID = commitID
        self.transcriptHash = transcriptHash
        self.pairRoot = pairRoot
        peerDeviceID = peerHello.deviceID
        peerRole = peerHello.role
        peerDisplayName = peerHello.displayName
    }

    public var description: String { "<redacted remote pairing agreement>" }
    public var debugDescription: String { description }

    /// Creates this device's signed proof of the authenticated pairing transcript.
    public func makeConfirmation() throws -> RemotePairingConfirmation {
        let unsigned = RemotePairingConfirmationUnsigned(
            protocolVersion: RemotePairingConfirmation.currentProtocolVersion,
            pairID: pairID,
            senderDeviceID: localIdentity.deviceID,
            senderRole: localIdentity.role,
            recipientDeviceID: peerHello.deviceID,
            transcriptHash: transcriptHash
        )
        let canonical = try remoteCanonicalData(unsigned)
        let tag = remoteHMAC(
            key: confirmationKey(senderRole: localIdentity.role),
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Confirmation.MAC.v1",
                canonical
            )
        )
        return RemotePairingConfirmation(
            protocolVersion: unsigned.protocolVersion,
            pairID: unsigned.pairID,
            senderDeviceID: unsigned.senderDeviceID,
            senderRole: unsigned.senderRole,
            recipientDeviceID: unsigned.recipientDeviceID,
            transcriptHash: unsigned.transcriptHash,
            confirmationTag: tag,
            signature: try localIdentity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Confirmation.Signature.v1",
                    canonical,
                    tag
                )
            )
        )
    }

    /// Verifies that the peer confirmation belongs to this exact agreement.
    public func verify(_ confirmation: RemotePairingConfirmation) throws {
        guard confirmation.protocolVersion == RemotePairingConfirmation.currentProtocolVersion else {
            throw RemoteSessionCoreError.unsupportedPairingVersion
        }
        guard confirmation.isStructurallyValid,
              confirmation.pairID == pairID,
              confirmation.senderDeviceID == peerHello.deviceID,
              confirmation.senderRole == peerHello.role,
              confirmation.recipientDeviceID == localIdentity.deviceID,
              remoteConstantTimeEqual(confirmation.transcriptHash, transcriptHash) else {
            throw RemoteSessionCoreError.pairingTranscriptMismatch
        }
        let canonical = try remoteCanonicalData(confirmation.unsigned)
        let expectedTag = remoteHMAC(
            key: confirmationKey(senderRole: peerHello.role),
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Confirmation.MAC.v1",
                canonical
            )
        )
        guard remoteConstantTimeEqual(confirmation.confirmationTag, expectedTag),
              remoteVerifySignature(
                confirmation.signature,
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Confirmation.Signature.v1",
                    canonical,
                    confirmation.confirmationTag
                ),
                publicKey: peerHello.signingPublicKey
              ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    /// Creates a role-valid signed commit for the requested persistence phase.
    public func makeCommit(phase: RemotePairingCommitPhase) throws -> RemotePairingCommit {
        try validateSender(role: localIdentity.role, phase: phase)
        let unsigned = RemotePairingCommitUnsigned(
            protocolVersion: RemotePairingCommit.currentProtocolVersion,
            pairID: pairID,
            commitID: commitID,
            senderDeviceID: localIdentity.deviceID,
            senderRole: localIdentity.role,
            recipientDeviceID: peerHello.deviceID,
            transcriptHash: transcriptHash,
            phase: phase
        )
        let canonical = try remoteCanonicalData(unsigned)
        let tag = remoteHMAC(
            key: commitKey(senderRole: localIdentity.role, phase: phase),
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Commit.MAC.v1",
                canonical
            )
        )
        return RemotePairingCommit(
            protocolVersion: unsigned.protocolVersion,
            pairID: unsigned.pairID,
            commitID: unsigned.commitID,
            senderDeviceID: unsigned.senderDeviceID,
            senderRole: unsigned.senderRole,
            recipientDeviceID: unsigned.recipientDeviceID,
            transcriptHash: unsigned.transcriptHash,
            phase: phase,
            commitTag: tag,
            signature: try localIdentity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Commit.Signature.v1",
                    canonical,
                    tag
                )
            )
        )
    }

    /// Verifies a peer commit's identity, transcript, phase, tag, and signature.
    public func verify(
        _ commit: RemotePairingCommit,
        expectedPhase: RemotePairingCommitPhase
    ) throws {
        guard commit.protocolVersion == RemotePairingCommit.currentProtocolVersion else {
            throw RemoteSessionCoreError.unsupportedPairingVersion
        }
        guard commit.isStructurallyValid,
              commit.phase == expectedPhase,
              commit.pairID == pairID,
              commit.commitID == commitID,
              commit.senderDeviceID == peerHello.deviceID,
              commit.senderRole == peerHello.role,
              commit.recipientDeviceID == localIdentity.deviceID,
              remoteConstantTimeEqual(commit.transcriptHash, transcriptHash) else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try validateSender(role: peerHello.role, phase: commit.phase)
        let canonical = try remoteCanonicalData(commit.unsigned)
        let expectedTag = remoteHMAC(
            key: commitKey(senderRole: peerHello.role, phase: commit.phase),
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Commit.MAC.v1",
                canonical
            )
        )
        guard remoteConstantTimeEqual(commit.commitTag, expectedTag),
              remoteVerifySignature(
                commit.signature,
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Commit.Signature.v1",
                    canonical,
                    commit.commitTag
                ),
                publicKey: peerHello.signingPublicKey
              ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    /// Produces persistent state only after the peer's confirmation and final role-specific
    /// commit are authenticated. A `.ready` rendezvous event alone can never reach this API.
    public func makePendingRecord(
        peerConfirmation: RemotePairingConfirmation,
        createdAt: Date = Date()
    ) throws -> RemotePairedDeviceRecord {
        try verify(peerConfirmation)
        return try makeRecord(createdAt: createdAt, state: .pending)
    }

    /// Produces an active durable record after the role-specific final commit is authenticated.
    public func finalize(
        peerConfirmation: RemotePairingConfirmation,
        finalPeerCommit: RemotePairingCommit,
        createdAt: Date = Date()
    ) throws -> RemotePairedDeviceRecord {
        try verify(peerConfirmation)
        let requiredPhase: RemotePairingCommitPhase = localIdentity.role == .host
            ? .acknowledgement
            : .completion
        try verify(finalPeerCommit, expectedPhase: requiredPhase)
        let state: RemotePairingPersistenceState = localIdentity.role == .host
            ? .acceptedReceived
            : .active
        let recoveryCommit = localIdentity.role == .viewer
            ? try makeCommit(phase: .activationAcknowledgement)
            : nil
        return try makeRecord(
            createdAt: createdAt,
            state: state,
            recoveryCommit: recoveryCommit
        )
    }

    private func makeRecord(
        createdAt: Date,
        state: RemotePairingPersistenceState,
        recoveryCommit: RemotePairingCommit? = nil
    ) throws -> RemotePairedDeviceRecord {
        return try RemotePairedDeviceRecord(
            pairID: pairID,
            commitID: commitID,
            localDeviceID: localIdentity.deviceID,
            localRole: localIdentity.role,
            localSigningPublicKey: localIdentity.signingPublicKey,
            remoteDeviceID: peerHello.deviceID,
            remoteRole: peerHello.role,
            remoteSigningPublicKey: peerHello.signingPublicKey,
            remoteDisplayName: peerHello.displayName,
            pairingTranscriptHash: transcriptHash,
            pairRootKey: pairRoot,
            createdAt: createdAt,
            pairingState: state,
            recoveryCommit: recoveryCommit
        )
    }

    private func confirmationKey(senderRole: RemotePeerRole) -> Data {
        remoteHKDF(
            input: pairRoot,
            salt: transcriptHash,
            label: "AudioStreamer.Pairing.Confirmation.\(senderRole.rawValue).v1"
        )
    }

    private func commitKey(
        senderRole: RemotePeerRole,
        phase: RemotePairingCommitPhase
    ) -> Data {
        remoteHKDF(
            input: pairRoot,
            salt: transcriptHash,
            label: "AudioStreamer.Pairing.Commit.\(senderRole.rawValue).\(phase.rawValue).v1"
        )
    }

    private func validateSender(
        role: RemotePeerRole,
        phase: RemotePairingCommitPhase
    ) throws {
        let isValid = switch phase {
        case .proposal, .completion:
            role == .host
        case .acknowledgement, .activationAcknowledgement:
            role == .viewer
        }
        guard isValid else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
    }
}

/// Canonical hello fields covered by the device-identity signature.
internal struct RemotePairingHelloUnsigned: Codable {
    let protocolVersion: UInt8
    let deviceID: UUID
    let role: RemotePeerRole
    let displayName: String?
    let signingPublicKey: Data
    let ephemeralKeyAgreementPublicKey: Data
    let nonce: Data
}

/// Canonical transcript-confirmation fields covered by the sender's signature.
internal struct RemotePairingConfirmationUnsigned: Codable {
    let protocolVersion: UInt8
    let pairID: UUID
    let senderDeviceID: UUID
    let senderRole: RemotePeerRole
    let recipientDeviceID: UUID
    let transcriptHash: Data
}

/// Canonical durable-commit fields covered by the sender's signature.
internal struct RemotePairingCommitUnsigned: Codable {
    let protocolVersion: UInt8
    let pairID: UUID
    let commitID: UUID
    let senderDeviceID: UUID
    let senderRole: RemotePeerRole
    let recipientDeviceID: UUID
    let transcriptHash: Data
    let phase: RemotePairingCommitPhase
}

private struct RemotePairingTranscript: Codable {
    let host: RemotePairingHello
    let viewer: RemotePairingHello
}
