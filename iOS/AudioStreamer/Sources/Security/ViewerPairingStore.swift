import CryptoKit
import Foundation
import RemoteSessionCore

/// Durable viewer-side identity and authenticated pairing record operations.
/// Loading an existing pair must validate that it is bound to the supplied local identity.
protocol ViewerPairingStoring {
    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity
    func loadPairedMac(for identity: RemoteDeviceIdentity) throws -> RemotePairedDeviceRecord?
    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws
    func deletePairedMac() throws
}

/// Stores proof that a one-time invitation crossed the rendezvous admission boundary.
/// The proof is separate from the durable paired-device record because a crash may occur between
/// those two persistence phases.
protocol WorldwideInvitationAdmissionStoring {
    func loadAdmittedInvitationDigest() throws -> Data?
    func saveAdmittedInvitationDigest(_ digest: Data) throws
    func deleteAdmittedInvitationDigest() throws
}

/// Persists only a one-way, domain-separated fingerprint of an invitation that has crossed
/// the consume-once rendezvous boundary. The invitation secret itself remains in its separate
/// Keychain item so the UI can explain what happened without ever silently retrying it.
struct WorldwideInvitationAdmissionKeychainStore: WorldwideInvitationAdmissionStoring {
    static let digestByteCount = 32

    private static let digestDomain = Data(
        "AudioStreamer.WorldwideInvitation.Admitted.v1\0".utf8
    )

    private let store: KeychainStore

    init(
        item: KeychainStore.Item = KeychainStore.worldwideInvitationAdmissionMarkerItem
    ) {
        store = KeychainStore(item: item)
    }

    func loadAdmittedInvitationDigest() throws -> Data? {
        guard let digest = try store.loadData() else { return nil }
        guard digest.count == Self.digestByteCount else {
            throw WorldwideInvitationAdmissionStoreError.invalidStoredDigest
        }
        return digest
    }

    func saveAdmittedInvitationDigest(_ digest: Data) throws {
        guard digest.count == Self.digestByteCount else {
            throw WorldwideInvitationAdmissionStoreError.invalidStoredDigest
        }
        try store.saveData(digest)
    }

    func deleteAdmittedInvitationDigest() throws {
        try store.deleteData()
    }

    static func digest(for input: String) throws -> Data {
        let invitation = try RemoteInvitationCode(input)
        var material = digestDomain
        // exportedCode is the canonical representation after parsing has normalized accepted
        // separators, case, and Crockford aliases. It is used transiently and never persisted.
        material.append(Data(invitation.exportedCode.utf8))
        return Data(SHA256.hash(data: material))
    }
}

/// Owns the iPhone's durable viewer identity and its authenticated Mac pairing.
///
/// Both Codable payloads contain long-lived secret material. They are stored only in stable,
/// this-device-only Keychain generic-password items and are never copied to UserDefaults.
struct ViewerPairingKeychainStore: ViewerPairingStoring {
    private let identityStore: KeychainStore
    private let pairedMacStore: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        identityItem: KeychainStore.Item = KeychainStore.viewerDeviceIdentityItem,
        pairedMacItem: KeychainStore.Item = KeychainStore.pairedMacItem
    ) {
        identityStore = KeychainStore(item: identityItem)
        pairedMacStore = KeychainStore(item: pairedMacItem)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity {
        if let identity = try loadViewerIdentity() {
            return identity
        }

        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        // Identity generation is not considered complete until the private material is durable;
        // silently returning an ephemeral replacement would permanently orphan an existing pair.
        do {
            try identityStore.saveData(try encoder.encode(identity))
        } catch let error as ViewerPairingStoreError {
            throw error
        } catch {
            throw ViewerPairingStoreError.identityPersistenceFailed
        }
        return identity
    }

    /// Strictly reads the durable viewer identity without silently creating a replacement.
    /// Update/recovery validation uses this boundary so a missing Keychain item is observable.
    func loadViewerIdentity() throws -> RemoteDeviceIdentity? {
        guard let stored = try identityStore.loadData() else { return nil }
        return try decodeViewerIdentity(stored)
    }

    func loadPairedMac(
        for identity: RemoteDeviceIdentity
    ) throws -> RemotePairedDeviceRecord? {
        try validateViewerIdentity(identity)
        guard let stored = try pairedMacStore.loadData() else { return nil }

        let record: RemotePairedDeviceRecord
        do {
            record = try decoder.decode(RemotePairedDeviceRecord.self, from: stored)
        } catch {
            throw ViewerPairingStoreError.invalidPairedMacRecord
        }
        try validate(record, for: identity)
        return record
    }

    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        try validateViewerIdentity(identity)
        try validate(record, for: identity)
        do {
            try pairedMacStore.saveData(try encoder.encode(record))
        } catch let error as ViewerPairingStoreError {
            throw error
        } catch {
            throw ViewerPairingStoreError.pairedMacPersistenceFailed
        }
    }

    func deletePairedMac() throws {
        do {
            try pairedMacStore.deleteData()
        } catch {
            throw ViewerPairingStoreError.pairedMacDeletionFailed
        }
    }

    private func decodeViewerIdentity(_ data: Data) throws -> RemoteDeviceIdentity {
        let identity: RemoteDeviceIdentity
        do {
            identity = try decoder.decode(RemoteDeviceIdentity.self, from: data)
        } catch {
            throw ViewerPairingStoreError.invalidViewerIdentity
        }
        try validateViewerIdentity(identity)
        return identity
    }

    private func validateViewerIdentity(_ identity: RemoteDeviceIdentity) throws {
        guard identity.version == RemoteDeviceIdentity.currentVersion,
              identity.role == .viewer else {
            throw ViewerPairingStoreError.invalidViewerIdentity
        }
    }

    private func validate(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        // Public-key and device identifiers must agree before interpreting the recovery phase.
        guard record.version == RemotePairedDeviceRecord.currentVersion,
              record.localRole == .viewer,
              record.remoteRole == .host,
              record.localDeviceID == identity.deviceID,
              record.localSigningPublicKey == identity.signingPublicKey else {
            throw ViewerPairingStoreError.invalidPairedMacRecord
        }

        // A viewer may crash between the durable pairing phases, so pending and ACK-issued
        // records are valid recovery state. Host-only state and internally inconsistent
        // recovery actions must never be surfaced as an iPhone pairing.
        switch record.pairingState {
        case .pending:
            guard record.recoveryAction == .awaitProposal else {
                throw ViewerPairingStoreError.invalidPairedMacRecord
            }
        case .acceptedIssued:
            guard case .resend(let acknowledgement) = record.recoveryAction,
                  validLocalRecoveryCommit(
                    acknowledgement,
                    expectedPhase: .acknowledgement,
                    record: record
                  ) else {
                throw ViewerPairingStoreError.invalidPairedMacRecord
            }
        case .active:
            switch record.recoveryAction {
            case .resend(let activation):
                guard validLocalRecoveryCommit(
                    activation,
                    expectedPhase: .activationAcknowledgement,
                    record: record
                ) else {
                    throw ViewerPairingStoreError.invalidPairedMacRecord
                }
            case .none, .awaitProposal, .issueProposal, .issueCompletion:
                throw ViewerPairingStoreError.invalidPairedMacRecord
            }
        case .acceptedReceived:
            throw ViewerPairingStoreError.invalidPairedMacRecord
        }
    }

    private func validLocalRecoveryCommit(
        _ commit: RemotePairingCommit,
        expectedPhase: RemotePairingCommitPhase,
        record: RemotePairedDeviceRecord
    ) -> Bool {
        commit.phase == expectedPhase
            && commit.pairID == record.pairID
            && commit.commitID == record.commitID
            && commit.senderDeviceID == record.localDeviceID
            && commit.senderRole == .viewer
            && commit.recipientDeviceID == record.remoteDeviceID
    }

}

/// Validation and persistence failures at the durable pairing boundary.
enum ViewerPairingStoreError: Error, Equatable {
    case invalidViewerIdentity
    case invalidPairedMacRecord
    case identityPersistenceFailed
    case pairedMacPersistenceFailed
    case pairedMacDeletionFailed
}

/// Corruption of the fixed-width admission digest stored in Keychain.
enum WorldwideInvitationAdmissionStoreError: Error, Equatable {
    case invalidStoredDigest
}
