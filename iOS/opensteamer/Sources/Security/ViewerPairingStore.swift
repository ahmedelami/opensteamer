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

    // This legacy domain is part of already-persisted admission markers. Renaming it would make a
    // consumed invitation appear new after an app update, so the rebrand deliberately preserves it.
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

/// One validated, same-service view of the two durable pairing credentials.
///
/// `identity == nil` implies both other fields are nil. A record without its owning identity is
/// corruption, not an empty namespace, and is rejected while constructing this snapshot.
struct ViewerPairingNamespaceSnapshot: Equatable, Sendable {
    let identity: RemoteDeviceIdentity?
    let encodedIdentity: Data?
    let pairedMac: RemotePairedDeviceRecord?

    static let empty = ViewerPairingNamespaceSnapshot(
        identity: nil,
        encodedIdentity: nil,
        pairedMac: nil
    )
}

/// Narrow same-namespace boundary used by the production compatibility selector.
///
/// Keeping this separate from `ViewerPairingStoring` preserves custom-store and protocol tests:
/// only the production selector can consult more than one Keychain service.
protocol ViewerPairingNamespaceStoring {
    func loadNamespaceSnapshot() throws -> ViewerPairingNamespaceSnapshot
    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity
    func preserveViewerIdentity(
        _ identity: RemoteDeviceIdentity,
        encodedIdentity: Data
    ) throws
    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws
    func deletePairedMac() throws
}

/// Owns one Keychain namespace containing the iPhone's durable viewer identity and Mac pairing.
///
/// Both Codable payloads contain long-lived secret material. They are stored only in stable,
/// this-device-only Keychain generic-password items and are never copied to UserDefaults. This
/// type deliberately remains single-namespace even when initialized with custom test items.
struct ViewerPairingKeychainStore: ViewerPairingStoring, ViewerPairingNamespaceStoring {
    private let identityStore: KeychainStore
    private let pairedMacStore: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        self.init(
            identityItem: KeychainStore.viewerDeviceIdentityItem,
            pairedMacItem: KeychainStore.pairedMacItem
        )
    }

    init(
        identityItem: KeychainStore.Item,
        pairedMacItem: KeychainStore.Item
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
            if try identityStore.insertDataIfAbsent(try encoder.encode(identity)) {
                return identity
            }
            // Another writer created the item after our initial read. Adopt only a valid durable
            // viewer identity rather than overwriting it with the locally generated candidate.
            guard let existingIdentity = try loadViewerIdentity() else {
                throw ViewerPairingStoreError.identityPersistenceFailed
            }
            return existingIdentity
        } catch let error as ViewerPairingStoreError {
            throw error
        } catch let error as KeychainStoreError {
            throw error
        } catch {
            throw ViewerPairingStoreError.identityPersistenceFailed
        }
    }

    /// Strictly reads the durable viewer identity without silently creating a replacement.
    /// Update/recovery validation uses this boundary so a missing Keychain item is observable.
    func loadViewerIdentity() throws -> RemoteDeviceIdentity? {
        guard let stored = try identityStore.loadData() else { return nil }
        return try decodeViewerIdentity(stored)
    }

    /// Reads both credentials from this service before interpreting either as a usable pair.
    /// Missing halves, malformed payloads, and binding mismatches fail closed.
    func loadNamespaceSnapshot() throws -> ViewerPairingNamespaceSnapshot {
        let encodedIdentity = try identityStore.loadData()
        let encodedPairedMac = try pairedMacStore.loadData()

        guard let encodedIdentity else {
            guard encodedPairedMac == nil else {
                throw ViewerPairingStoreError.invalidPairedMacRecord
            }
            return .empty
        }

        let identity = try decodeViewerIdentity(encodedIdentity)
        guard let encodedPairedMac else {
            return ViewerPairingNamespaceSnapshot(
                identity: identity,
                encodedIdentity: encodedIdentity,
                pairedMac: nil
            )
        }

        let record = try decodePairedMacRecord(encodedPairedMac)
        try validate(record, for: identity)
        return ViewerPairingNamespaceSnapshot(
            identity: identity,
            encodedIdentity: encodedIdentity,
            pairedMac: record
        )
    }

    func loadPairedMac(
        for identity: RemoteDeviceIdentity
    ) throws -> RemotePairedDeviceRecord? {
        try validateViewerIdentity(identity)
        guard let stored = try pairedMacStore.loadData() else { return nil }

        let record = try decodePairedMacRecord(stored)
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
        } catch let error as KeychainStoreError {
            throw error
        } catch {
            throw ViewerPairingStoreError.pairedMacPersistenceFailed
        }
    }

    func deletePairedMac() throws {
        do {
            try pairedMacStore.deleteData()
        } catch let error as KeychainStoreError {
            throw error
        } catch {
            throw ViewerPairingStoreError.pairedMacDeletionFailed
        }
    }

    /// Copies a previously validated identity without replacing a different identity that may
    /// already own the destination namespace. The exact encoded bytes are retained on insertion.
    func preserveViewerIdentity(
        _ identity: RemoteDeviceIdentity,
        encodedIdentity: Data
    ) throws {
        try validateViewerIdentity(identity)
        guard try decodeViewerIdentity(encodedIdentity) == identity else {
            throw ViewerPairingStoreError.viewerIdentityConflict
        }

        if let existingData = try identityStore.loadData() {
            guard try decodeViewerIdentity(existingData) == identity else {
                throw ViewerPairingStoreError.viewerIdentityConflict
            }
            return
        }

        if try identityStore.insertDataIfAbsent(encodedIdentity) {
            return
        }

        // Another writer won the add race. Accept only the same exact semantic identity.
        guard let racedData = try identityStore.loadData(),
              try decodeViewerIdentity(racedData) == identity else {
            throw ViewerPairingStoreError.viewerIdentityConflict
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

    private func decodePairedMacRecord(_ data: Data) throws -> RemotePairedDeviceRecord {
        do {
            return try decoder.decode(RemotePairedDeviceRecord.self, from: data)
        } catch {
            throw ViewerPairingStoreError.invalidPairedMacRecord
        }
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

/// Production selector for the current and pre-build-34 iOS pairing namespaces.
///
/// Selection is resolved once as an atomic identity/record snapshot and cached for the lifetime
/// of the app state. A primary identity by itself is an explicit unpaired state, so legacy data is
/// consulted only when the primary namespace is entirely empty. No method ever combines an
/// identity from one service with a record from the other.
final class ViewerPairingNamespaceSelectorStore: ViewerPairingStoring {
    private enum Namespace {
        case primary
        case legacy
    }

    private struct Selection {
        let namespace: Namespace
        let identity: RemoteDeviceIdentity
        let encodedIdentity: Data
        var pairedMac: RemotePairedDeviceRecord?
    }

    private let primaryStore: any ViewerPairingNamespaceStoring
    private let legacyStore: any ViewerPairingNamespaceStoring
    private var selection: Selection?

    init() {
        primaryStore = ViewerPairingKeychainStore(
            identityItem: KeychainStore.viewerDeviceIdentityItem,
            pairedMacItem: KeychainStore.pairedMacItem
        )
        legacyStore = ViewerPairingKeychainStore(
            identityItem: KeychainStore.legacyViewerDeviceIdentityItem,
            pairedMacItem: KeychainStore.legacyPairedMacItem
        )
    }

    /// Explicit dependency injection is the only custom initializer. Tests supplying custom
    /// stores therefore cannot accidentally consult either production Keychain service.
    init(
        primaryStore: any ViewerPairingNamespaceStoring,
        legacyStore: any ViewerPairingNamespaceStoring
    ) {
        self.primaryStore = primaryStore
        self.legacyStore = legacyStore
    }

    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity {
        guard let selection = try resolveSelection(createPrimaryIdentityWhenEmpty: true) else {
            throw ViewerPairingStoreError.identityPersistenceFailed
        }
        return selection.identity
    }

    func loadPairedMac(
        for identity: RemoteDeviceIdentity
    ) throws -> RemotePairedDeviceRecord? {
        guard let selection = try resolveSelection(createPrimaryIdentityWhenEmpty: true),
              selection.identity == identity else {
            throw ViewerPairingStoreError.invalidViewerIdentity
        }
        return selection.pairedMac
    }

    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        guard var selection = try resolveSelection(createPrimaryIdentityWhenEmpty: true),
              selection.identity == identity else {
            throw ViewerPairingStoreError.invalidViewerIdentity
        }

        switch selection.namespace {
        case .primary:
            try primaryStore.savePairedMac(record, for: identity)
        case .legacy:
            try legacyStore.savePairedMac(record, for: identity)
        }
        selection.pairedMac = record
        self.selection = selection
    }

    /// Explicit revocation removes both records while preserving both durable identities.
    ///
    /// The selected record is deleted last. For a legacy selection, the exact encoded identity is
    /// first promoted into an empty (or accepted if equal in an existing) primary namespace. Thus
    /// even a partial deletion failure cannot make the forgotten legacy pair reappear on relaunch.
    func deletePairedMac() throws {
        guard let selection = try resolveSelection(createPrimaryIdentityWhenEmpty: false) else {
            // A direct delete against two empty namespaces must not manufacture an identity.
            try legacyStore.deletePairedMac()
            try primaryStore.deletePairedMac()
            return
        }

        switch selection.namespace {
        case .primary:
            try legacyStore.deletePairedMac()
            try primaryStore.deletePairedMac()

        case .legacy:
            let currentPrimary = try primaryStore.loadNamespaceSnapshot()
            let primaryEncodedIdentity: Data
            if let primaryIdentity = currentPrimary.identity,
               let encodedIdentity = currentPrimary.encodedIdentity {
                guard primaryIdentity == selection.identity else {
                    throw ViewerPairingStoreError.viewerIdentityConflict
                }
                primaryEncodedIdentity = encodedIdentity
            } else {
                try primaryStore.preserveViewerIdentity(
                    selection.identity,
                    encodedIdentity: selection.encodedIdentity
                )
                primaryEncodedIdentity = selection.encodedIdentity
            }

            try primaryStore.deletePairedMac()
            try legacyStore.deletePairedMac()
            self.selection = Selection(
                namespace: .primary,
                identity: selection.identity,
                encodedIdentity: primaryEncodedIdentity,
                pairedMac: nil
            )
            return
        }

        self.selection = Selection(
            namespace: .primary,
            identity: selection.identity,
            encodedIdentity: selection.encodedIdentity,
            pairedMac: nil
        )
    }

    private func resolveSelection(
        createPrimaryIdentityWhenEmpty: Bool
    ) throws -> Selection? {
        if let selection {
            return selection
        }

        let primary = try primaryStore.loadNamespaceSnapshot()
        if let selected = selection(from: primary, namespace: .primary) {
            selection = selected
            return selected
        }

        let legacy = try legacyStore.loadNamespaceSnapshot()
        if let selected = selection(from: legacy, namespace: .legacy),
           selected.pairedMac != nil {
            selection = selected
            return selected
        }

        // A legacy identity without its bound record is not a migratable pair. Keep it untouched
        // and establish a new identity only in the current primary namespace.
        guard createPrimaryIdentityWhenEmpty else {
            return nil
        }

        _ = try primaryStore.loadOrCreateViewerIdentity()
        let createdPrimary = try primaryStore.loadNamespaceSnapshot()
        guard let selected = selection(from: createdPrimary, namespace: .primary) else {
            throw ViewerPairingStoreError.identityPersistenceFailed
        }
        selection = selected
        return selected
    }

    private func selection(
        from snapshot: ViewerPairingNamespaceSnapshot,
        namespace: Namespace
    ) -> Selection? {
        guard let identity = snapshot.identity,
              let encodedIdentity = snapshot.encodedIdentity else {
            return nil
        }
        return Selection(
            namespace: namespace,
            identity: identity,
            encodedIdentity: encodedIdentity,
            pairedMac: snapshot.pairedMac
        )
    }
}

/// Validation and persistence failures at the durable pairing boundary.
enum ViewerPairingStoreError: Error, Equatable {
    case invalidViewerIdentity
    case invalidPairedMacRecord
    case viewerIdentityConflict
    case identityPersistenceFailed
    case pairedMacPersistenceFailed
    case pairedMacDeletionFailed
}

/// Corruption of the fixed-width admission digest stored in Keychain.
enum WorldwideInvitationAdmissionStoreError: Error, Equatable {
    case invalidStoredDigest
}
