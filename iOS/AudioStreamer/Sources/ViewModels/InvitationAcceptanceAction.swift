import Foundation
import RemoteSessionCore

/// Holds invitation admission and cleanup behind durably persisted pairing boundaries.
/// Rendezvous readiness alone proves no device identity and must not turn a saved code into a
/// locally blocked credential when there is not yet a pairing record that can resume after launch.
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

    /// Persists the consume-once admission boundary exactly once, after the viewer's recoverable
    /// acknowledgement state has already been saved. Call this immediately before transmitting
    /// that acknowledgement. A process death can then resume from the paired-device record
    /// instead of presenting the saved one-time code as an unusable credential.
    mutating func persistAdmissionAfterRecoverablePairing(
        _ record: RemotePairedDeviceRecord,
        generation: UUID
    ) throws {
        guard self.generation == generation, !didPersistAdmission else { return }
        guard record.pairingState == .acceptedIssued else {
            throw InvitationAcceptanceError.pairingIsNotRecoverable
        }
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
    case pairingIsNotRecoverable
    case pairingIsNotActive
}
