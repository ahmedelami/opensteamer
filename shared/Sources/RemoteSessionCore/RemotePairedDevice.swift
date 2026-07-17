import CryptoKit
import Foundation

public enum RemotePairingPersistenceState: String, Codable, CaseIterable, Sendable {
    /// Pair root is persisted, but the three-way commit is not durably accepted yet.
    case pending
    /// Viewer durably stored its acknowledgement before sending or resending it.
    case acceptedIssued
    /// Host durably stored the viewer acknowledgement before issuing completion.
    case acceptedReceived
    /// The role-specific commit completion condition has been reached.
    case active
}

public enum RemotePairingRecoveryAction: Equatable, Sendable {
    case awaitProposal
    case issueProposal
    case resend(RemotePairingCommit)
    case issueCompletion
    case none
}

/// Durable state created only after an authenticated pairing commit.
///
/// The encoded form contains the pair root key and monotonic reconnect counters. Persist it
/// atomically in a stable, this-device-only Keychain item; never write it to logs or defaults.
public struct RemotePairedDeviceRecord: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let pairID: UUID
    public let commitID: UUID
    public let localDeviceID: UUID
    public let localRole: RemotePeerRole
    public let localSigningPublicKey: Data
    public let remoteDeviceID: UUID
    public let remoteRole: RemotePeerRole
    public let remoteSigningPublicKey: Data
    public let remoteDisplayName: String?
    public let createdAt: Date
    public internal(set) var pairingState: RemotePairingPersistenceState
    public internal(set) var nextOutboundReconnectSequence: UInt64
    public internal(set) var highestAcceptedReconnectSequence: UInt64

    private let pairingTranscriptHash: Data
    private let pairRootKey: Data
    private var recoveryCommit: RemotePairingCommit?

    internal init(
        pairID: UUID,
        commitID: UUID,
        localDeviceID: UUID,
        localRole: RemotePeerRole,
        localSigningPublicKey: Data,
        remoteDeviceID: UUID,
        remoteRole: RemotePeerRole,
        remoteSigningPublicKey: Data,
        remoteDisplayName: String?,
        pairingTranscriptHash: Data,
        pairRootKey: Data,
        createdAt: Date,
        pairingState: RemotePairingPersistenceState = .active,
        recoveryCommit: RemotePairingCommit? = nil,
        nextOutboundReconnectSequence: UInt64 = 1,
        highestAcceptedReconnectSequence: UInt64 = 0,
        version: UInt8 = RemotePairedDeviceRecord.currentVersion
    ) throws {
        guard version == Self.currentVersion,
              !remoteUUIDIsZero(pairID),
              !remoteUUIDIsZero(commitID),
              !remoteUUIDIsZero(localDeviceID),
              !remoteUUIDIsZero(remoteDeviceID),
              localDeviceID != remoteDeviceID,
              localRole != remoteRole,
              localSigningPublicKey.count == 32,
              remoteSigningPublicKey.count == 32,
              !remoteConstantTimeEqual(localSigningPublicKey, remoteSigningPublicKey),
              remoteValidDisplayName(remoteDisplayName),
              pairingTranscriptHash.count == 32,
              pairRootKey.count == 32,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              nextOutboundReconnectSequence > 0 else {
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }

        self.version = version
        self.pairID = pairID
        self.commitID = commitID
        self.localDeviceID = localDeviceID
        self.localRole = localRole
        self.localSigningPublicKey = localSigningPublicKey
        self.remoteDeviceID = remoteDeviceID
        self.remoteRole = remoteRole
        self.remoteSigningPublicKey = remoteSigningPublicKey
        self.remoteDisplayName = remoteDisplayName
        self.pairingTranscriptHash = pairingTranscriptHash
        self.pairRootKey = pairRootKey
        self.createdAt = createdAt
        self.pairingState = pairingState
        self.recoveryCommit = recoveryCommit
        self.nextOutboundReconnectSequence = nextOutboundReconnectSequence
        self.highestAcceptedReconnectSequence = highestAcceptedReconnectSequence
        try validatePersistenceState()
    }

    /// Stable, pair-scoped credential for exchanging only signed reconnect control messages.
    /// WebRTC SDP/ICE/media must use the fresh session credential from a reconnect handshake.
    public func availabilityLocator() throws -> RemoteAvailabilityLocator {
        // Availability is the authenticated recovery path for interrupted commits. Media and
        // reconnect APIs remain gated on `.active` below.
        return try RemoteAvailabilityLocator(
            pairRootKey: pairRootKey,
            pairID: pairID,
            pairingTranscriptHash: pairingTranscriptHash,
            localRole: localRole
        )
    }

    public func availabilityCredential(
        exchangeID: RemoteAvailabilityExchangeID
    ) throws -> RemoteRendezvousCredential {
        try availabilityLocator().credential(exchangeID: exchangeID)
    }

    public var description: String { "<redacted paired remote device>" }
    public var debugDescription: String { description }

    public var recoveryAction: RemotePairingRecoveryAction {
        switch pairingState {
        case .pending:
            if let recoveryCommit { return .resend(recoveryCommit) }
            return localRole == .host ? .issueProposal : .awaitProposal
        case .acceptedIssued:
            return recoveryCommit.map(RemotePairingRecoveryAction.resend) ?? .awaitProposal
        case .acceptedReceived:
            return recoveryCommit.map(RemotePairingRecoveryAction.resend) ?? .issueCompletion
        case .active:
            return recoveryCommit.map(RemotePairingRecoveryAction.resend) ?? .none
        }
    }

    /// Reserves and signs a fresh viewer reconnect request. Persist the mutated record before
    /// transmitting `request`; that prevents a crash from reusing the same monotonic sequence.
    public mutating func beginReconnect(
        using identity: RemoteDeviceIdentity
    ) throws -> RemoteReconnectInitiator {
        try beginReconnect(
            using: identity,
            ephemeralPrivateKeyRawRepresentation: Curve25519.KeyAgreement.PrivateKey()
                .rawRepresentation,
            nonce: remoteRandomBytes(count: 32)
        )
    }

    internal mutating func beginReconnect(
        using identity: RemoteDeviceIdentity,
        ephemeralPrivateKeyRawRepresentation: Data,
        nonce: Data
    ) throws -> RemoteReconnectInitiator {
        guard pairingState == .active else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try validateLocalIdentity(identity, expectedRole: .viewer)
        guard nextOutboundReconnectSequence < UInt64.max else {
            throw RemoteSessionCoreError.sequenceExhausted
        }
        let initiator = try RemoteReconnectInitiator(
            record: self,
            identity: identity,
            sequence: nextOutboundReconnectSequence,
            ephemeralPrivateKeyRawRepresentation: ephemeralPrivateKeyRawRepresentation,
            nonce: nonce
        )
        nextOutboundReconnectSequence += 1
        return initiator
    }

    /// Authenticates a strictly newer viewer request and creates the matching host response.
    /// Persist the mutated record before sending the response so a replay remains rejected.
    public mutating func respond(
        to request: RemoteReconnectRequest,
        using identity: RemoteDeviceIdentity
    ) throws -> RemoteReconnectResponder {
        try respond(
            to: request,
            using: identity,
            ephemeralPrivateKeyRawRepresentation: Curve25519.KeyAgreement.PrivateKey()
                .rawRepresentation,
            nonce: remoteRandomBytes(count: 32)
        )
    }

    internal mutating func respond(
        to request: RemoteReconnectRequest,
        using identity: RemoteDeviceIdentity,
        ephemeralPrivateKeyRawRepresentation: Data,
        nonce: Data
    ) throws -> RemoteReconnectResponder {
        guard pairingState == .active else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try validateLocalIdentity(identity, expectedRole: .host)
        try validate(request: request)
        guard request.sequence > highestAcceptedReconnectSequence else {
            throw RemoteSessionCoreError.staleReconnectSequence
        }
        let responder = try RemoteReconnectResponder(
            record: self,
            identity: identity,
            request: request,
            ephemeralPrivateKeyRawRepresentation: ephemeralPrivateKeyRawRepresentation,
            nonce: nonce
        )
        highestAcceptedReconnectSequence = request.sequence
        return responder
    }

    /// Host-side, crash-safe proposal preparation. Persist this mutated record before send.
    public mutating func prepareProposal(
        using identity: RemoteDeviceIdentity
    ) throws -> RemotePairingCommit {
        try validateLocalIdentity(identity, expectedRole: .host)
        guard pairingState == .pending else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        if let recoveryCommit {
            guard recoveryCommit.phase == .proposal else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
            return recoveryCommit
        }
        let commit = try makeLocalCommit(phase: .proposal, identity: identity)
        recoveryCommit = commit
        return commit
    }

    /// Viewer-side, crash-safe acknowledgement preparation. The returned ACK is idempotent.
    /// Persist this mutated record before sending it.
    public mutating func prepareAcknowledgement(
        after proposal: RemotePairingCommit,
        using identity: RemoteDeviceIdentity
    ) throws -> RemotePairingCommit {
        try validateLocalIdentity(identity, expectedRole: .viewer)
        guard pairingState == .pending || pairingState == .acceptedIssued else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try verifyPeerCommit(proposal, expectedPhase: .proposal)
        if pairingState == .acceptedIssued, let recoveryCommit {
            return recoveryCommit
        }
        let acknowledgement = try makeLocalCommit(phase: .acknowledgement, identity: identity)
        pairingState = .acceptedIssued
        recoveryCommit = acknowledgement
        return acknowledgement
    }

    /// Host persists the high-water commit state before preparing a completion.
    public mutating func acceptAcknowledgement(_ acknowledgement: RemotePairingCommit) throws {
        guard localRole == .host,
              pairingState == .pending
                || pairingState == .acceptedReceived
                || pairingState == .active else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try verifyPeerCommit(acknowledgement, expectedPhase: .acknowledgement)
        guard pairingState == .pending else { return }
        pairingState = .acceptedReceived
        recoveryCommit = nil
    }

    /// Host prepares an idempotent completion. Persist this state before transmitting it.
    public mutating func prepareCompletion(
        using identity: RemoteDeviceIdentity
    ) throws -> RemotePairingCommit {
        try validateLocalIdentity(identity, expectedRole: .host)
        guard pairingState == .acceptedReceived || pairingState == .active else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        if pairingState == .active {
            // A delayed, authenticated ACK may be replayed after the host has already activated.
            // Recreate an equivalent authenticated completion for the viewer without reopening
            // recovery state or making an otherwise valid active record undecodable.
            guard recoveryCommit == nil else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
            return try makeLocalCommit(phase: .completion, identity: identity)
        }
        if let recoveryCommit {
            guard recoveryCommit.phase == .completion else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
            return recoveryCommit
        }
        let completion = try makeLocalCommit(phase: .completion, identity: identity)
        recoveryCommit = completion
        return completion
    }

    /// Records a successful send, but deliberately does not activate the host. Only the
    /// viewer's signed activation acknowledgement can do that.
    public mutating func markCompletionSent(commitID: UUID) throws {
        guard localRole == .host,
              self.commitID == commitID else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        switch pairingState {
        case .acceptedReceived:
            guard recoveryCommit?.phase == .completion else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
            // Keep `.acceptedReceived` and the exact completion across every send/crash boundary.
        case .active:
            // A replay response is deliberately ephemeral; activation already completed.
            guard recoveryCommit == nil else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
        case .pending, .acceptedIssued:
            throw RemoteSessionCoreError.invalidPairingCommit
        }
    }

    /// Viewer authenticates completion, persists active state, and returns an idempotent signed
    /// activation acknowledgement. Persist the record before sending the returned value.
    public mutating func acceptCompletion(
        _ completion: RemotePairingCommit,
        using identity: RemoteDeviceIdentity
    ) throws -> RemotePairingCommit {
        try validateLocalIdentity(identity, expectedRole: .viewer)
        guard localRole == .viewer else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        if pairingState == .active {
            try verifyPeerCommit(completion, expectedPhase: .completion)
            guard let recoveryCommit,
                  recoveryCommit.phase == .activationAcknowledgement else {
                throw RemoteSessionCoreError.invalidPairingCommit
            }
            return recoveryCommit
        }
        guard pairingState == .acceptedIssued else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try verifyPeerCommit(completion, expectedPhase: .completion)
        let acknowledgement = try makeLocalCommit(
            phase: .activationAcknowledgement,
            identity: identity
        )
        pairingState = .active
        recoveryCommit = acknowledgement
        return acknowledgement
    }

    /// Host becomes active only after the viewer proves durable receipt of completion.
    public mutating func acceptActivationAcknowledgement(
        _ acknowledgement: RemotePairingCommit
    ) throws {
        guard localRole == .host,
              pairingState == .acceptedReceived || pairingState == .active else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        try verifyPeerCommit(
            acknowledgement,
            expectedPhase: .activationAcknowledgement
        )
        pairingState = .active
        recoveryCommit = nil
    }

    internal var rootKeyMaterial: Data { pairRootKey }

    private func makeLocalCommit(
        phase: RemotePairingCommitPhase,
        identity: RemoteDeviceIdentity
    ) throws -> RemotePairingCommit {
        let validRole = switch phase {
        case .proposal, .completion: localRole == .host
        case .acknowledgement, .activationAcknowledgement: localRole == .viewer
        }
        guard validRole else { throw RemoteSessionCoreError.invalidPairingCommit }
        let unsigned = RemotePairingCommitUnsigned(
            protocolVersion: RemotePairingCommit.currentProtocolVersion,
            pairID: pairID,
            commitID: commitID,
            senderDeviceID: localDeviceID,
            senderRole: localRole,
            recipientDeviceID: remoteDeviceID,
            transcriptHash: pairingTranscriptHash,
            phase: phase
        )
        let canonical = try remoteCanonicalData(unsigned)
        let tag = remoteHMAC(
            key: commitKey(senderRole: localRole, phase: phase),
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
            phase: unsigned.phase,
            commitTag: tag,
            signature: try identity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Commit.Signature.v1",
                    canonical,
                    tag
                )
            )
        )
    }

    private func verifyPeerCommit(
        _ commit: RemotePairingCommit,
        expectedPhase: RemotePairingCommitPhase
    ) throws {
        guard commit.isStructurallyValid,
              commit.pairID == pairID,
              commit.commitID == commitID,
              commit.senderDeviceID == remoteDeviceID,
              commit.senderRole == remoteRole,
              commit.recipientDeviceID == localDeviceID,
              commit.phase == expectedPhase,
              remoteConstantTimeEqual(commit.transcriptHash, pairingTranscriptHash) else {
            throw RemoteSessionCoreError.invalidPairingCommit
        }
        let canonical = try remoteCanonicalData(commit.unsigned)
        let expectedTag = remoteHMAC(
            key: commitKey(senderRole: remoteRole, phase: expectedPhase),
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
                publicKey: remoteSigningPublicKey
              ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    private func commitKey(
        senderRole: RemotePeerRole,
        phase: RemotePairingCommitPhase
    ) -> Data {
        remoteHKDF(
            input: pairRootKey,
            salt: pairingTranscriptHash,
            label: "AudioStreamer.Pairing.Commit.\(senderRole.rawValue).\(phase.rawValue).v1"
        )
    }

    private func validatePersistenceState() throws {
        let expectedRecoveryPhase: RemotePairingCommitPhase?
        let recoveryMayBeAbsent: Bool
        switch (localRole, pairingState) {
        case (.host, .pending):
            expectedRecoveryPhase = .proposal
            recoveryMayBeAbsent = true
        case (.host, .acceptedReceived):
            expectedRecoveryPhase = .completion
            recoveryMayBeAbsent = true
        case (.host, .active):
            expectedRecoveryPhase = nil
            recoveryMayBeAbsent = true
        case (.viewer, .pending):
            expectedRecoveryPhase = nil
            recoveryMayBeAbsent = true
        case (.viewer, .acceptedIssued):
            expectedRecoveryPhase = .acknowledgement
            recoveryMayBeAbsent = false
        case (.viewer, .active):
            expectedRecoveryPhase = .activationAcknowledgement
            recoveryMayBeAbsent = false
        case (.host, .acceptedIssued), (.viewer, .acceptedReceived):
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }

        guard let recoveryCommit else {
            guard recoveryMayBeAbsent else {
                throw RemoteSessionCoreError.invalidPairedDeviceRecord
            }
            return
        }
        guard let expectedRecoveryPhase,
              recoveryCommit.protocolVersion == RemotePairingCommit.currentProtocolVersion,
              recoveryCommit.isStructurallyValid,
              recoveryCommit.phase == expectedRecoveryPhase,
              recoveryCommit.pairID == pairID,
              recoveryCommit.commitID == commitID,
              recoveryCommit.senderDeviceID == localDeviceID,
              recoveryCommit.senderRole == localRole,
              recoveryCommit.recipientDeviceID == remoteDeviceID,
              remoteConstantTimeEqual(
                recoveryCommit.transcriptHash,
                pairingTranscriptHash
              ) else {
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }
        let canonical: Data
        do {
            canonical = try remoteCanonicalData(recoveryCommit.unsigned)
        } catch {
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }
        let expectedTag = remoteHMAC(
            key: commitKey(senderRole: localRole, phase: expectedRecoveryPhase),
            data: remoteDomainSeparated(
                "AudioStreamer.Pairing.Commit.MAC.v1",
                canonical
            )
        )
        guard remoteConstantTimeEqual(recoveryCommit.commitTag, expectedTag),
              remoteVerifySignature(
                recoveryCommit.signature,
                for: remoteDomainSeparated(
                    "AudioStreamer.Pairing.Commit.Signature.v1",
                    canonical,
                    recoveryCommit.commitTag
                ),
                publicKey: localSigningPublicKey
              ) else {
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }
    }

    internal func validateLocalIdentity(
        _ identity: RemoteDeviceIdentity,
        expectedRole: RemotePeerRole
    ) throws {
        guard localRole == expectedRole,
              identity.matches(
                deviceID: localDeviceID,
                role: localRole,
                publicKey: localSigningPublicKey
              ) else {
            throw RemoteSessionCoreError.deviceIdentityMismatch
        }
    }

    internal func validate(request: RemoteReconnectRequest) throws {
        guard request.protocolVersion == RemoteReconnectRequest.currentProtocolVersion else {
            throw RemoteSessionCoreError.unsupportedReconnectVersion
        }
        guard request.isStructurallyValid,
              request.pairID == pairID,
              request.requesterDeviceID == remoteDeviceID,
              request.requesterRole == remoteRole,
              request.targetDeviceID == localDeviceID,
              remoteRole == .viewer,
              localRole == .host else {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let unsigned = try remoteCanonicalData(request.unsigned)
        guard remoteVerifySignature(
            request.signature,
            for: remoteDomainSeparated(
                "AudioStreamer.Reconnect.Request.Signature.v1",
                unsigned
            ),
            publicKey: remoteSigningPublicKey
        ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case pairID
        case commitID
        case localDeviceID
        case localRole
        case localSigningPublicKey
        case remoteDeviceID
        case remoteRole
        case remoteSigningPublicKey
        case remoteDisplayName
        case pairingTranscriptHash
        case pairRootKey
        case createdAt
        case pairingState
        case recoveryCommit
        case nextOutboundReconnectSequence
        case highestAcceptedReconnectSequence
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                pairID: container.decode(UUID.self, forKey: .pairID),
                commitID: container.decode(UUID.self, forKey: .commitID),
                localDeviceID: container.decode(UUID.self, forKey: .localDeviceID),
                localRole: container.decode(RemotePeerRole.self, forKey: .localRole),
                localSigningPublicKey: container.decode(Data.self, forKey: .localSigningPublicKey),
                remoteDeviceID: container.decode(UUID.self, forKey: .remoteDeviceID),
                remoteRole: container.decode(RemotePeerRole.self, forKey: .remoteRole),
                remoteSigningPublicKey: container.decode(Data.self, forKey: .remoteSigningPublicKey),
                remoteDisplayName: container.decodeIfPresent(String.self, forKey: .remoteDisplayName),
                pairingTranscriptHash: container.decode(Data.self, forKey: .pairingTranscriptHash),
                pairRootKey: container.decode(Data.self, forKey: .pairRootKey),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                pairingState: container.decode(
                    RemotePairingPersistenceState.self,
                    forKey: .pairingState
                ),
                recoveryCommit: container.decodeIfPresent(
                    RemotePairingCommit.self,
                    forKey: .recoveryCommit
                ),
                nextOutboundReconnectSequence: container.decode(
                    UInt64.self,
                    forKey: .nextOutboundReconnectSequence
                ),
                highestAcceptedReconnectSequence: container.decode(
                    UInt64.self,
                    forKey: .highestAcceptedReconnectSequence
                ),
                version: container.decode(UInt8.self, forKey: .version)
            )
        } catch let error as RemoteSessionCoreError {
            throw error
        } catch {
            throw RemoteSessionCoreError.invalidPairedDeviceRecord
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(pairID, forKey: .pairID)
        try container.encode(commitID, forKey: .commitID)
        try container.encode(localDeviceID, forKey: .localDeviceID)
        try container.encode(localRole, forKey: .localRole)
        try container.encode(localSigningPublicKey, forKey: .localSigningPublicKey)
        try container.encode(remoteDeviceID, forKey: .remoteDeviceID)
        try container.encode(remoteRole, forKey: .remoteRole)
        try container.encode(remoteSigningPublicKey, forKey: .remoteSigningPublicKey)
        try container.encodeIfPresent(remoteDisplayName, forKey: .remoteDisplayName)
        try container.encode(pairingTranscriptHash, forKey: .pairingTranscriptHash)
        try container.encode(pairRootKey, forKey: .pairRootKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(pairingState, forKey: .pairingState)
        try container.encodeIfPresent(recoveryCommit, forKey: .recoveryCommit)
        try container.encode(nextOutboundReconnectSequence, forKey: .nextOutboundReconnectSequence)
        try container.encode(
            highestAcceptedReconnectSequence,
            forKey: .highestAcceptedReconnectSequence
        )
    }
}

public struct RemoteReconnectRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let pairID: UUID
    public let requesterDeviceID: UUID
    public let requesterRole: RemotePeerRole
    public let targetDeviceID: UUID
    public let sequence: UInt64
    public let ephemeralKeyAgreementPublicKey: Data
    public let nonce: Data
    public let signature: Data

    internal var unsigned: RemoteReconnectRequestUnsigned {
        RemoteReconnectRequestUnsigned(
            protocolVersion: protocolVersion,
            pairID: pairID,
            requesterDeviceID: requesterDeviceID,
            requesterRole: requesterRole,
            targetDeviceID: targetDeviceID,
            sequence: sequence,
            ephemeralKeyAgreementPublicKey: ephemeralKeyAgreementPublicKey,
            nonce: nonce
        )
    }

    internal var isStructurallyValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && !remoteUUIDIsZero(pairID)
            && !remoteUUIDIsZero(requesterDeviceID)
            && !remoteUUIDIsZero(targetDeviceID)
            && requesterDeviceID != targetDeviceID
            && requesterRole == .viewer
            && sequence > 0
            && ephemeralKeyAgreementPublicKey.count == 32
            && nonce.count == 32
            && signature.count == 64
    }
}

public struct RemoteReconnectResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let pairID: UUID
    public let requesterDeviceID: UUID
    public let responderDeviceID: UUID
    public let responderRole: RemotePeerRole
    public let requestSequence: UInt64
    public let requestDigest: Data
    public let ephemeralKeyAgreementPublicKey: Data
    public let nonce: Data
    public let signature: Data

    internal var unsigned: RemoteReconnectResponseUnsigned {
        RemoteReconnectResponseUnsigned(
            protocolVersion: protocolVersion,
            pairID: pairID,
            requesterDeviceID: requesterDeviceID,
            responderDeviceID: responderDeviceID,
            responderRole: responderRole,
            requestSequence: requestSequence,
            requestDigest: requestDigest,
            ephemeralKeyAgreementPublicKey: ephemeralKeyAgreementPublicKey,
            nonce: nonce
        )
    }

    internal var isStructurallyValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && !remoteUUIDIsZero(pairID)
            && !remoteUUIDIsZero(requesterDeviceID)
            && !remoteUUIDIsZero(responderDeviceID)
            && requesterDeviceID != responderDeviceID
            && responderRole == .host
            && requestSequence > 0
            && requestDigest.count == 32
            && ephemeralKeyAgreementPublicKey.count == 32
            && nonce.count == 32
            && signature.count == 64
    }
}

public struct RemoteReconnectInitiator: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let request: RemoteReconnectRequest

    private let record: RemotePairedDeviceRecord
    private let ephemeralPrivateKey: Data

    internal init(
        record: RemotePairedDeviceRecord,
        identity: RemoteDeviceIdentity,
        sequence: UInt64,
        ephemeralPrivateKeyRawRepresentation: Data,
        nonce: Data
    ) throws {
        guard record.localRole == .viewer,
              record.remoteRole == .host,
              sequence > 0,
              ephemeralPrivateKeyRawRepresentation.count == 32,
              nonce.count == 32 else {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        do {
            ephemeral = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKeyRawRepresentation
            )
        } catch {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let unsigned = RemoteReconnectRequestUnsigned(
            protocolVersion: RemoteReconnectRequest.currentProtocolVersion,
            pairID: record.pairID,
            requesterDeviceID: record.localDeviceID,
            requesterRole: .viewer,
            targetDeviceID: record.remoteDeviceID,
            sequence: sequence,
            ephemeralKeyAgreementPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce
        )
        let canonical = try remoteCanonicalData(unsigned)
        request = RemoteReconnectRequest(
            protocolVersion: unsigned.protocolVersion,
            pairID: unsigned.pairID,
            requesterDeviceID: unsigned.requesterDeviceID,
            requesterRole: unsigned.requesterRole,
            targetDeviceID: unsigned.targetDeviceID,
            sequence: unsigned.sequence,
            ephemeralKeyAgreementPublicKey: unsigned.ephemeralKeyAgreementPublicKey,
            nonce: unsigned.nonce,
            signature: try identity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Reconnect.Request.Signature.v1",
                    canonical
                )
            )
        )
        self.record = record
        ephemeralPrivateKey = ephemeralPrivateKeyRawRepresentation
    }

    public var description: String { "<redacted remote reconnect initiator>" }
    public var debugDescription: String { description }

    public func complete(
        with response: RemoteReconnectResponse
    ) throws -> RemoteRendezvousCredential {
        guard response.protocolVersion == RemoteReconnectResponse.currentProtocolVersion else {
            throw RemoteSessionCoreError.unsupportedReconnectVersion
        }
        let expectedRequestDigest = remoteSHA256(try remoteCanonicalData(request))
        guard response.isStructurallyValid,
              response.pairID == record.pairID,
              response.requesterDeviceID == record.localDeviceID,
              response.responderDeviceID == record.remoteDeviceID,
              response.responderRole == .host,
              response.requestSequence == request.sequence,
              remoteConstantTimeEqual(response.requestDigest, expectedRequestDigest) else {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let canonicalResponse = try remoteCanonicalData(response.unsigned)
        guard remoteVerifySignature(
            response.signature,
            for: remoteDomainSeparated(
                "AudioStreamer.Reconnect.Response.Signature.v1",
                canonicalResponse
            ),
            publicKey: record.remoteSigningPublicKey
        ) else {
            throw RemoteSessionCoreError.authenticationFailed
        }

        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKey
            )
            publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: response.ephemeralKeyAgreementPublicKey
            )
        } catch {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
        guard !remoteIsAllZero(shared.withUnsafeBytes { Data($0) }) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
        return try remoteSessionCredential(
            record: record,
            request: request,
            response: response,
            sharedSecret: shared
        )
    }
}

public struct RemoteReconnectResponder: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let response: RemoteReconnectResponse
    public let credential: RemoteRendezvousCredential

    internal init(
        record: RemotePairedDeviceRecord,
        identity: RemoteDeviceIdentity,
        request: RemoteReconnectRequest,
        ephemeralPrivateKeyRawRepresentation: Data,
        nonce: Data
    ) throws {
        guard record.localRole == .host,
              record.remoteRole == .viewer,
              ephemeralPrivateKeyRawRepresentation.count == 32,
              nonce.count == 32 else {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let requesterPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: ephemeralPrivateKeyRawRepresentation
            )
            requesterPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: request.ephemeralKeyAgreementPublicKey
            )
        } catch {
            throw RemoteSessionCoreError.invalidReconnectMessage
        }
        let requestDigest = remoteSHA256(try remoteCanonicalData(request))
        let unsigned = RemoteReconnectResponseUnsigned(
            protocolVersion: RemoteReconnectResponse.currentProtocolVersion,
            pairID: record.pairID,
            requesterDeviceID: request.requesterDeviceID,
            responderDeviceID: record.localDeviceID,
            responderRole: .host,
            requestSequence: request.sequence,
            requestDigest: requestDigest,
            ephemeralKeyAgreementPublicKey: privateKey.publicKey.rawRepresentation,
            nonce: nonce
        )
        let canonical = try remoteCanonicalData(unsigned)
        let builtResponse = RemoteReconnectResponse(
            protocolVersion: unsigned.protocolVersion,
            pairID: unsigned.pairID,
            requesterDeviceID: unsigned.requesterDeviceID,
            responderDeviceID: unsigned.responderDeviceID,
            responderRole: unsigned.responderRole,
            requestSequence: unsigned.requestSequence,
            requestDigest: unsigned.requestDigest,
            ephemeralKeyAgreementPublicKey: unsigned.ephemeralKeyAgreementPublicKey,
            nonce: unsigned.nonce,
            signature: try identity.signature(
                for: remoteDomainSeparated(
                    "AudioStreamer.Reconnect.Response.Signature.v1",
                    canonical
                )
            )
        )
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: requesterPublicKey)
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
        guard !remoteIsAllZero(shared.withUnsafeBytes { Data($0) }) else {
            throw RemoteSessionCoreError.authenticationFailed
        }
        response = builtResponse
        credential = try remoteSessionCredential(
            record: record,
            request: request,
            response: builtResponse,
            sharedSecret: shared
        )
    }

    public var description: String { "<redacted remote reconnect responder>" }
    public var debugDescription: String { description }
}

internal struct RemoteReconnectRequestUnsigned: Codable {
    let protocolVersion: UInt8
    let pairID: UUID
    let requesterDeviceID: UUID
    let requesterRole: RemotePeerRole
    let targetDeviceID: UUID
    let sequence: UInt64
    let ephemeralKeyAgreementPublicKey: Data
    let nonce: Data
}

internal struct RemoteReconnectResponseUnsigned: Codable {
    let protocolVersion: UInt8
    let pairID: UUID
    let requesterDeviceID: UUID
    let responderDeviceID: UUID
    let responderRole: RemotePeerRole
    let requestSequence: UInt64
    let requestDigest: Data
    let ephemeralKeyAgreementPublicKey: Data
    let nonce: Data
}

private struct RemoteReconnectTranscript: Codable {
    let request: RemoteReconnectRequest
    let response: RemoteReconnectResponse
}

private func remoteSessionCredential(
    record: RemotePairedDeviceRecord,
    request: RemoteReconnectRequest,
    response: RemoteReconnectResponse,
    sharedSecret: SharedSecret
) throws -> RemoteRendezvousCredential {
    let transcript = RemoteReconnectTranscript(request: request, response: response)
    let transcriptHash = remoteSHA256(
        remoteDomainSeparated(
            "AudioStreamer.Reconnect.Transcript.v1",
            try remoteCanonicalData(transcript)
        )
    )
    var keyMaterial = Data()
    keyMaterial.append(record.rootKeyMaterial)
    keyMaterial.append(sharedSecret.withUnsafeBytes { Data($0) })
    let sessionRoot = remoteHKDF(
        input: keyMaterial,
        salt: transcriptHash,
        label: "AudioStreamer.Reconnect.SessionRoot.v1"
    )
    return try RemoteRendezvousCredential(
        keyMaterial: sessionRoot,
        salt: transcriptHash,
        context: "session"
    )
}
