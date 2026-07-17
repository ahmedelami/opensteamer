import Foundation
import RemoteSessionCore

/// Holds destructive invitation cleanup behind an authenticated, durably persisted pairing.
/// A rendezvous `.ready` event consumes transport admission but proves no device identity.
@MainActor
struct InvitationAcceptanceAction {
    private var generation: UUID?
    private var admissionAction: (@MainActor () throws -> Void)?
    private var action: (@MainActor (RemotePairedDeviceRecord) throws -> Void)?
    private var didPersistAdmission = false

    mutating func arm(
        generation: UUID,
        onAdmitted admissionAction: (@MainActor () throws -> Void)? = nil,
        action: @escaping @MainActor (RemotePairedDeviceRecord) throws -> Void
    ) {
        self.generation = generation
        self.admissionAction = admissionAction
        self.action = action
        didPersistAdmission = false
    }

    /// Persists the consume-once admission boundary exactly once. Ready still does not erase
    /// the invitation: authenticated active pairing must be durable before cleanup may run.
    mutating func rendezvousBecameReady(generation: UUID) throws {
        guard self.generation == generation, !didPersistAdmission else { return }
        try admissionAction?()
        didPersistAdmission = true
    }

    /// Runs exactly once for the armed generation. The action must synchronously persist the
    /// authenticated record before it clears the invitation. If persistence throws, this gate
    /// remains armed and the invitation remains available for recovery.
    @discardableResult
    mutating func completeAuthenticatedPairing(
        _ record: RemotePairedDeviceRecord,
        generation: UUID
    ) throws -> Bool {
        guard self.generation == generation, let action else { return false }
        guard record.pairingState == .active else {
            throw InvitationAcceptanceError.pairingIsNotActive
        }
        try action(record)
        self.generation = nil
        admissionAction = nil
        self.action = nil
        didPersistAdmission = false
        return true
    }

    mutating func cancel(generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        admissionAction = nil
        action = nil
        didPersistAdmission = false
    }
}

enum InvitationAcceptanceError: Error, Equatable {
    case pairingIsNotActive
}
