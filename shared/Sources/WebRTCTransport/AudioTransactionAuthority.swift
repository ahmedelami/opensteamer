#if os(iOS)
import Foundation
import OpensteamerAudioTransactionAuthority

public struct AudioTransactionOperationReceipt: Equatable, Hashable, Sendable {
    public let operationID: UUID
    public let operationRevision: UInt64
    public let authorityEpoch: UInt64

    public init(
        operationID: UUID,
        operationRevision: UInt64,
        authorityEpoch: UInt64
    ) {
        self.operationID = operationID
        self.operationRevision = operationRevision
        self.authorityEpoch = authorityEpoch
    }

    public var nativeContext: WebRTCIOSAudioTransactionContext {
        WebRTCIOSAudioTransactionContext(
            operationID: operationID,
            authorityEpoch: authorityEpoch,
            operationRevision: operationRevision
        )
    }
}

public struct AudioTransactionBoundaryReceipt: Equatable, Sendable {
    public let reducerRevision: UInt64
    public let authorityEpoch: UInt64
    public let blocker: AudioTransactionOperationReceipt?
}

public struct AudioTransactionProofReceipt: Equatable, Sendable {
    public let operation: AudioTransactionOperationReceipt
    public let proofRevision: UInt64
}

public struct AudioTransactionTarget: Equatable, Sendable {
    public let category: String
    public let mode: String
    public let categoryOptionsRawValue: UInt
    public let routeSharingPolicyRawValue: Int
    public let inputRequired: Bool

    public init(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        routeSharingPolicyRawValue: Int,
        inputRequired: Bool
    ) {
        self.category = category
        self.mode = mode
        self.categoryOptionsRawValue = categoryOptionsRawValue
        self.routeSharingPolicyRawValue = routeSharingPolicyRawValue
        self.inputRequired = inputRequired
    }
}

public struct AudioTransactionSnapshot: Equatable, Sendable {
    public let reducerRevision: UInt64
    public let authorityEpoch: UInt64
    public let gcWatermark: UInt64
    public let lastObservationSequence: UInt64
    public let retiredOperationRevisionWatermark: UInt64
    public let tombstoneCount: UInt64
    public let deviceInstanceGeneration: UInt64
    public let observationRegistrationGeneration: UInt64
    public let currentOperation: AudioTransactionOperationReceipt?
}

public enum AudioTransactionRejection: Equatable, Sendable {
    case staleRevision
    case staleAuthority
    case staleOperation
    case duplicate
    case invalidInput
    case targetMismatch
    case blockerNotAllowed
    case noCurrentOperation
    case capacityExceeded
    case blockerRequired
    case counterExhausted
    case unknown(UInt32)
}

public enum AudioTransactionIgnoreReason: Equatable, Sendable {
    case exactDuplicate
    case currentOperationAlreadyTerminal
    case retiredOperation
    case watermarkRetiredOperation
    case staleDeviceGeneration
    case unknown(UInt32)
}

public enum AudioTransactionRuntimeFailure: Equatable, Sendable {
    case unavailable
    case abiMismatch
    case nullPointer
    case poisoned
    case unknown(UInt32)
}

public enum AudioTransactionDecision: Equatable, Sendable {
    case armed(
        operation: AudioTransactionOperationReceipt,
        proof: AudioTransactionProofReceipt,
        predecessor: AudioTransactionOperationReceipt?
    )
    case boundaryApplied(AudioTransactionBoundaryReceipt)
    case nativeAcknowledged(AudioTransactionOperationReceipt)
    case observationAccepted(
        operation: AudioTransactionOperationReceipt,
        proof: AudioTransactionProofReceipt
    )
    case abortedUnpublished(AudioTransactionOperationReceipt)
    case waitingForNativeAcknowledgement(
        AudioTransactionOperationReceipt
    )
    case completed(AudioTransactionOperationReceipt)
    case failedClosed(AudioTransactionOperationReceipt?)
    case ignored(
        reason: AudioTransactionIgnoreReason,
        operation: AudioTransactionOperationReceipt?,
        blocker: AudioTransactionOperationReceipt?
    )
    case garbageCollected(
        snapshot: AudioTransactionSnapshot,
        operation: AudioTransactionOperationReceipt
    )
    case deviceBound(AudioTransactionSnapshot)
    case deviceRetired(
        snapshot: AudioTransactionSnapshot,
        formerCurrent: AudioTransactionOperationReceipt?
    )
    case rejected(AudioTransactionRejection)
    case runtimeFailure(AudioTransactionRuntimeFailure)
}

/// Thin ownership wrapper around the Rust reducer. All C structs are copied values and all calls
/// are serialized by the reducer's native mutex; no Swift closure, object layout, or string crosses
/// the FFI boundary.
@MainActor
public final class AudioTransactionAuthority {
    private final class NativeStorage: @unchecked Sendable {
        let pointer: OpaquePointer?

        init(pointer: OpaquePointer?) {
            self.pointer = pointer
        }

        deinit {
            if let pointer {
                osata_authority_destroy(pointer)
            }
        }
    }

    private nonisolated let storage: NativeStorage
    private let abiIsCompatible: Bool

    public init(initialAuthorityEpoch: UInt64 = 1) {
        abiIsCompatible = osata_abi_version() == OSATA_ABI_VERSION
        storage = NativeStorage(
            pointer: abiIsCompatible
                ? osata_authority_create(initialAuthorityEpoch)
                : nil
        )
    }

    public var snapshot: AudioTransactionSnapshot? {
        guard abiIsCompatible,
              let native = storage.pointer else { return nil }
        var raw = osata_snapshot_t()
        guard osata_authority_snapshot(native, &raw) == OSATA_RUNTIME_OK,
              raw.abi_version == OSATA_ABI_VERSION else {
            return nil
        }
        return Self.snapshot(from: raw)
    }

    public func arm(
        operationID: UUID,
        target: AudioTransactionTarget,
        expectedReducerRevision: UInt64,
        observationHead: UInt64
    ) -> AudioTransactionDecision {
        guard let target = Self.nativeTarget(from: target) else {
            return .rejected(.invalidInput)
        }
        return invoke { native, output in
            osata_authority_arm(
                native,
                expectedReducerRevision,
                observationHead,
                Self.nativeUUID(from: operationID),
                target,
                output
            )
        }
    }

    public func bindDevice(
        _ binding: WebRTCIOSAudioTransactionDeviceBinding,
        expectedReducerRevision: UInt64
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_bind_device(
                native,
                expectedReducerRevision,
                binding.deviceInstanceGeneration,
                binding.observationRegistrationGeneration,
                output
            )
        }
    }

    public func retireDevice(
        _ receipt: WebRTCIOSAudioCategoryDeviceTeardownReceipt,
        expectedReducerRevision: UInt64
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_retire_device(
                native,
                expectedReducerRevision,
                Self.nativeDeviceTeardownReceipt(from: receipt),
                output
            )
        }
    }

    public func applyBoundary(
        expectedReducerRevision: UInt64,
        observationHead: UInt64
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_apply_boundary(
                native,
                expectedReducerRevision,
                observationHead,
                output
            )
        }
    }

    public func armSuccessor(
        operationID: UUID,
        target: AudioTransactionTarget,
        boundary: AudioTransactionBoundaryReceipt,
        observationHead: UInt64
    ) -> AudioTransactionDecision {
        guard let target = Self.nativeTarget(from: target) else {
            return .rejected(.invalidInput)
        }
        return invoke { native, output in
            osata_authority_arm_successor(
                native,
                Self.nativeBoundary(from: boundary),
                observationHead,
                Self.nativeUUID(from: operationID),
                target,
                output
            )
        }
    }

    public func abortUnpublished(
        _ operation: AudioTransactionOperationReceipt,
        expectedReducerRevision: UInt64
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_abort_unpublished(
                native,
                expectedReducerRevision,
                Self.nativeOperation(from: operation),
                output
            )
        }
    }

    public func acknowledgeNative(
        _ receipt: WebRTCIOSPlayoutRecoveryReceipt
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_acknowledge_native(
                native,
                Self.nativeRecoveryReceipt(from: receipt),
                output
            )
        }
    }

    public func observe(
        _ receipt: WebRTCIOSAudioCategoryObservationReceipt
    ) -> AudioTransactionDecision {
        guard let receipt = Self.nativeObservationReceipt(from: receipt) else {
            return .failedClosed(receipt.transaction.map {
                AudioTransactionOperationReceipt(
                    operationID: $0.operationID,
                    operationRevision: $0.operationRevision,
                    authorityEpoch: $0.authorityEpoch
                )
            })
        }
        return invoke { native, output in
            osata_authority_observe(native, receipt, output)
        }
    }

    public func resolveProof(
        _ receipt: AudioTransactionProofReceipt,
        succeeded: Bool
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_resolve_proof(
                native,
                Self.nativeProof(from: receipt),
                succeeded
                    ? OSATA_PROOF_OUTCOME_ACCEPTED
                    : OSATA_PROOF_OUTCOME_REJECTED,
                output
            )
        }
    }

    public func collectRetired(
        _ receipt: WebRTCIOSAudioCategoryDrainReceipt
    ) -> AudioTransactionDecision {
        invoke { native, output in
            osata_authority_collect_retired(
                native,
                Self.nativeDrainReceipt(from: receipt),
                output
            )
        }
    }

    private func invoke(
        _ body: (
            OpaquePointer,
            UnsafeMutablePointer<osata_decision_t>
        ) -> UInt32
    ) -> AudioTransactionDecision {
        guard abiIsCompatible else {
            return .runtimeFailure(.abiMismatch)
        }
        guard let native = storage.pointer else {
            return .runtimeFailure(.unavailable)
        }
        var raw = osata_decision_t()
        let status = body(native, &raw)
        guard status == OSATA_RUNTIME_OK else {
            return .runtimeFailure(Self.runtimeFailure(from: status))
        }
        guard raw.abi_version == OSATA_ABI_VERSION else {
            return .runtimeFailure(.abiMismatch)
        }
        return Self.decision(from: raw, authority: self)
    }

    private static func decision(
        from raw: osata_decision_t,
        authority: AudioTransactionAuthority
    ) -> AudioTransactionDecision {
        guard isCanonicalPresenceFlag(raw.has_operation),
              isCanonicalPresenceFlag(raw.has_boundary),
              isCanonicalPresenceFlag(raw.has_proof),
              isCanonicalPresenceFlag(raw.has_blocker) else {
            return .runtimeFailure(.abiMismatch)
        }
        let operationIsPresent = raw.has_operation == 1
        let boundaryIsPresent = raw.has_boundary == 1
        let proofIsPresent = raw.has_proof == 1
        let blockerIsPresent = raw.has_blocker == 1
        let hasRejection = raw.rejection != 0
        let hasIgnoreReason = raw.ignore_reason != 0

        switch raw.kind {
        case OSATA_DECISION_ARMED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  proofIsPresent,
                  !hasRejection,
                  !hasIgnoreReason,
                  nativeOperationsMatch(
                    raw.proof.operation,
                    raw.operation
                  ) else {
                return .runtimeFailure(.abiMismatch)
            }
            return .armed(
                operation: operation(from: raw.operation),
                proof: proof(from: raw.proof),
                predecessor: blockerIsPresent
                    ? operation(from: raw.blocker)
                    : nil
            )
        case OSATA_DECISION_BOUNDARY_APPLIED:
            guard !operationIsPresent,
                  boundaryIsPresent,
                  !proofIsPresent,
                  !hasRejection,
                  !hasIgnoreReason,
                  isCanonicalPresenceFlag(
                    raw.boundary.has_blocker
                  ),
                  blockerIsPresent
                    == (raw.boundary.has_blocker == 1),
                  !blockerIsPresent
                    || nativeOperationsMatch(
                        raw.blocker,
                        raw.boundary.blocker
                    ) else {
                return .runtimeFailure(.abiMismatch)
            }
            return .boundaryApplied(boundary(from: raw.boundary))
        case OSATA_DECISION_NATIVE_ACKNOWLEDGED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            return .nativeAcknowledged(operation(from: raw.operation))
        case OSATA_DECISION_OBSERVATION_ACCEPTED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason,
                  nativeOperationsMatch(
                    raw.proof.operation,
                    raw.operation
                  ) else {
                return .runtimeFailure(.abiMismatch)
            }
            return .observationAccepted(
                operation: operation(from: raw.operation),
                proof: proof(from: raw.proof)
            )
        case OSATA_DECISION_ABORTED_UNPUBLISHED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            return .abortedUnpublished(
                operation(from: raw.operation)
            )
        case OSATA_DECISION_WAITING_FOR_NATIVE_ACKNOWLEDGEMENT:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            return .waitingForNativeAcknowledgement(
                operation(from: raw.operation)
            )
        case OSATA_DECISION_COMPLETED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            return .completed(operation(from: raw.operation))
        case OSATA_DECISION_FAILED_CLOSED:
            guard !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            return .failedClosed(
                operationIsPresent
                    ? operation(from: raw.operation)
                    : nil
            )
        case OSATA_DECISION_IGNORED:
            guard !boundaryIsPresent,
                  !proofIsPresent,
                  !hasRejection,
                  let reason = ignoreReason(from: raw.ignore_reason) else {
                return .runtimeFailure(.abiMismatch)
            }
            return .ignored(
                reason: reason,
                operation: operationIsPresent
                    ? operation(from: raw.operation)
                    : nil,
                blocker: blockerIsPresent
                    ? operation(from: raw.blocker)
                    : nil
            )
        case OSATA_DECISION_GARBAGE_COLLECTED:
            guard operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            guard let snapshot = authority.snapshot,
                  snapshot.reducerRevision == raw.reducer_revision,
                  snapshot.authorityEpoch == raw.authority_epoch else {
                return .runtimeFailure(.unavailable)
            }
            return .garbageCollected(
                snapshot: snapshot,
                operation: operation(from: raw.operation)
            )
        case OSATA_DECISION_DEVICE_BOUND:
            guard !operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            guard let snapshot = authority.snapshot,
                  snapshot.reducerRevision == raw.reducer_revision,
                  snapshot.authorityEpoch == raw.authority_epoch else {
                return .runtimeFailure(.unavailable)
            }
            return .deviceBound(snapshot)
        case OSATA_DECISION_DEVICE_RETIRED:
            guard !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasRejection,
                  !hasIgnoreReason else {
                return .runtimeFailure(.abiMismatch)
            }
            guard let snapshot = authority.snapshot,
                  snapshot.reducerRevision == raw.reducer_revision,
                  snapshot.authorityEpoch == raw.authority_epoch else {
                return .runtimeFailure(.unavailable)
            }
            return .deviceRetired(
                snapshot: snapshot,
                formerCurrent: operationIsPresent
                    ? operation(from: raw.operation)
                    : nil
            )
        case OSATA_DECISION_REJECTED:
            guard !operationIsPresent,
                  !boundaryIsPresent,
                  !proofIsPresent,
                  !blockerIsPresent,
                  !hasIgnoreReason,
                  let rejection = rejection(from: raw.rejection) else {
                return .runtimeFailure(.abiMismatch)
            }
            return .rejected(rejection)
        default:
            return .runtimeFailure(.abiMismatch)
        }
    }

    private static func isCanonicalPresenceFlag(_ value: UInt32) -> Bool {
        value == 0 || value == 1
    }

    private static func nativeOperationsMatch(
        _ lhs: osata_operation_receipt_t,
        _ rhs: osata_operation_receipt_t
    ) -> Bool {
        lhs.operation_id.high == rhs.operation_id.high
            && lhs.operation_id.low == rhs.operation_id.low
            && lhs.operation_revision == rhs.operation_revision
            && lhs.authority_epoch == rhs.authority_epoch
    }

    private static func nativeTarget(
        from target: AudioTransactionTarget
    ) -> osata_target_t? {
        let category: UInt32
        switch target.category {
        case "AVAudioSessionCategoryPlayback":
            category = OSATA_CATEGORY_PLAYBACK
        case "AVAudioSessionCategoryPlayAndRecord":
            category = OSATA_CATEGORY_PLAY_AND_RECORD
        default:
            return nil
        }
        guard target.mode == "AVAudioSessionModeDefault",
              (category == OSATA_CATEGORY_PLAY_AND_RECORD)
                == target.inputRequired else {
            return nil
        }
        var raw = osata_target_t()
        raw.category = category
        raw.mode = OSATA_MODE_DEFAULT
        raw.options = UInt64(target.categoryOptionsRawValue)
        raw.route_sharing_policy = Int64(
            target.routeSharingPolicyRawValue
        )
        raw.input_required = target.inputRequired ? 1 : 0
        raw.reserved = 0
        return raw
    }

    private static func nativeObservationReceipt(
        from receipt: WebRTCIOSAudioCategoryObservationReceipt
    ) -> osata_native_observation_receipt_t? {
        let expected = AudioTransactionTarget(
            category: receipt.expectedCategory,
            mode: receipt.expectedMode,
            categoryOptionsRawValue:
                receipt.expectedCategoryOptionsRawValue,
            routeSharingPolicyRawValue:
                receipt.expectedRouteSharingPolicyRawValue,
            inputRequired: receipt.inputRequired
        )
        let observed = AudioTransactionTarget(
            category: receipt.observedCategory,
            mode: receipt.observedMode,
            categoryOptionsRawValue:
                receipt.observedCategoryOptionsRawValue,
            routeSharingPolicyRawValue:
                receipt.observedRouteSharingPolicyRawValue,
            inputRequired: receipt.inputRequired
        )
        guard let expectedTarget = nativeTarget(from: expected),
              let observedTarget = nativeTarget(from: observed) else {
            return nil
        }
        var raw = osata_native_observation_receipt_t()
        if let transaction = receipt.transaction {
            raw.app_operation = nativeOperation(
                from: AudioTransactionOperationReceipt(
                    operationID: transaction.operationID,
                    operationRevision: transaction.operationRevision,
                    authorityEpoch: transaction.authorityEpoch
                )
            )
            raw.has_app_operation = 1
        }
        raw.app_operation_tag_generation =
            receipt.appOperationTagGeneration
        raw.device_instance_generation =
            receipt.deviceInstanceGeneration
        raw.native_transaction_identifier =
            receipt.nativeTransactionIdentifier
        raw.notification_sequence = receipt.notificationSequence
        raw.transaction_observer_sequence_baseline =
            receipt.transactionObserverSequenceBaseline
        raw.transaction_configuration_generation =
            receipt.transactionConfigurationGeneration
        raw.observed_configuration_generation =
            receipt.observedConfigurationGeneration
        raw.transaction_system_audio_generation =
            receipt.transactionSystemAudioGeneration
        raw.observed_system_audio_generation =
            receipt.observedSystemAudioGeneration
        raw.observed_at_nanoseconds = receipt.observedAtNanoseconds
        raw.transaction_deadline_nanoseconds =
            receipt.transactionDeadlineNanoseconds
        raw.disposition = dispositionRawValue(receipt.disposition)
        raw.transaction_state_at_ingress =
            transactionStateRawValue(
                receipt.transactionStateAtIngress
            )
        raw.policy_tuple_is_exact = receipt.policyTupleIsExact ? 1 : 0
        raw.transaction_evidence_is_exact =
            receipt.transactionEvidenceIsExact ? 1 : 0
        raw.input_required = receipt.inputRequired ? 1 : 0
        raw.reserved = 0
        raw.expected_target = expectedTarget
        raw.observed_target = observedTarget
        return raw
    }

    private static func nativeRecoveryReceipt(
        from receipt: WebRTCIOSPlayoutRecoveryReceipt
    ) -> osata_native_recovery_receipt_t {
        var raw = osata_native_recovery_receipt_t()
        raw.operation = nativeOperation(
            from: AudioTransactionOperationReceipt(
                operationID: receipt.transaction.operationID,
                operationRevision:
                    receipt.transaction.operationRevision,
                authorityEpoch: receipt.transaction.authorityEpoch
            )
        )
        raw.authorization_generation = receipt.authorizationGeneration
        raw.terminal_generation = receipt.terminalGeneration
        switch receipt.outcome {
        case .pending:
            raw.outcome = OSATA_NATIVE_OUTCOME_PENDING
        case .accepted:
            raw.outcome = OSATA_NATIVE_OUTCOME_ACCEPTED
        case .rejected:
            raw.outcome = OSATA_NATIVE_OUTCOME_REJECTED
        case .revoked:
            raw.outcome = OSATA_NATIVE_OUTCOME_REVOKED
        }
        raw.policy_matches_requested_target =
            receipt.policyMatchesRequestedTarget ? 1 : 0
        return raw
    }

    private static func nativeDrainReceipt(
        from receipt: WebRTCIOSAudioCategoryDrainReceipt
    ) -> osata_native_drain_receipt_t {
        var raw = osata_native_drain_receipt_t()
        raw.operation = nativeOperation(
            from: AudioTransactionOperationReceipt(
                operationID: receipt.transaction.operationID,
                operationRevision:
                    receipt.transaction.operationRevision,
                authorityEpoch: receipt.transaction.authorityEpoch
            )
        )
        raw.app_operation_tag_generation =
            receipt.appOperationTagGeneration
        raw.native_transaction_identifier =
            receipt.nativeTransactionIdentifier
        raw.transaction_configuration_generation =
            receipt.transactionConfigurationGeneration
        raw.system_audio_generation = receipt.systemAudioGeneration
        raw.notification_sequence_watermark =
            receipt.notificationSequenceWatermark
        raw.observation_registration_generation =
            receipt.observationRegistrationGeneration
        raw.drain_generation = receipt.drainGeneration
        raw.device_instance_generation =
            receipt.deviceInstanceGeneration
        switch receipt.bindingState {
        case .staged:
            raw.binding_state = OSATA_DRAIN_BINDING_STATE_STAGED
        case .bound:
            raw.binding_state = OSATA_DRAIN_BINDING_STATE_BOUND
        }
        raw.ingress_in_flight_count = receipt.ingressInFlightCount
        raw.reserved0 = 0
        raw.reserved1 = 0
        return raw
    }

    private static func nativeDeviceTeardownReceipt(
        from receipt: WebRTCIOSAudioCategoryDeviceTeardownReceipt
    ) -> osata_native_device_teardown_receipt_t {
        var raw = osata_native_device_teardown_receipt_t()
        raw.device_instance_generation =
            receipt.deviceInstanceGeneration
        raw.observation_registration_generation =
            receipt.observationRegistrationGeneration
        raw.notification_sequence_watermark =
            receipt.notificationSequenceWatermark
        raw.teardown_generation = receipt.teardownGeneration
        raw.ingress_in_flight_count = receipt.ingressInFlightCount
        raw.reserved0 = 0
        raw.reserved1 = 0
        raw.reserved2 = 0
        return raw
    }

    private static func nativeBoundary(
        from receipt: AudioTransactionBoundaryReceipt
    ) -> osata_boundary_receipt_t {
        var raw = osata_boundary_receipt_t()
        raw.reducer_revision = receipt.reducerRevision
        raw.authority_epoch = receipt.authorityEpoch
        if let blocker = receipt.blocker {
            raw.has_blocker = 1
            raw.blocker = nativeOperation(from: blocker)
        }
        return raw
    }

    private static func nativeProof(
        from receipt: AudioTransactionProofReceipt
    ) -> osata_proof_receipt_t {
        var raw = osata_proof_receipt_t()
        raw.operation = nativeOperation(from: receipt.operation)
        raw.proof_revision = receipt.proofRevision
        return raw
    }

    private static func nativeOperation(
        from receipt: AudioTransactionOperationReceipt
    ) -> osata_operation_receipt_t {
        var raw = osata_operation_receipt_t()
        raw.operation_id = nativeUUID(from: receipt.operationID)
        raw.operation_revision = receipt.operationRevision
        raw.authority_epoch = receipt.authorityEpoch
        return raw
    }

    private static func nativeUUID(from uuid: UUID) -> osata_uuid_t {
        var bytes = uuid.uuid
        var raw = osata_uuid_t()
        withUnsafeBytes(of: &bytes) { buffer in
            raw.high = UInt64(bigEndian: buffer.loadUnaligned(
                fromByteOffset: 0,
                as: UInt64.self
            ))
            raw.low = UInt64(bigEndian: buffer.loadUnaligned(
                fromByteOffset: 8,
                as: UInt64.self
            ))
        }
        return raw
    }

    private static func operation(
        from raw: osata_operation_receipt_t
    ) -> AudioTransactionOperationReceipt {
        AudioTransactionOperationReceipt(
            operationID: uuid(from: raw.operation_id),
            operationRevision: raw.operation_revision,
            authorityEpoch: raw.authority_epoch
        )
    }

    private static func boundary(
        from raw: osata_boundary_receipt_t
    ) -> AudioTransactionBoundaryReceipt {
        AudioTransactionBoundaryReceipt(
            reducerRevision: raw.reducer_revision,
            authorityEpoch: raw.authority_epoch,
            blocker: raw.has_blocker == 1
                ? operation(from: raw.blocker)
                : nil
        )
    }

    private static func proof(
        from raw: osata_proof_receipt_t
    ) -> AudioTransactionProofReceipt {
        AudioTransactionProofReceipt(
            operation: operation(from: raw.operation),
            proofRevision: raw.proof_revision
        )
    }

    private static func snapshot(
        from raw: osata_snapshot_t
    ) -> AudioTransactionSnapshot? {
        guard isCanonicalPresenceFlag(
            raw.has_current_operation
        ) else { return nil }
        return AudioTransactionSnapshot(
            reducerRevision: raw.reducer_revision,
            authorityEpoch: raw.authority_epoch,
            gcWatermark: raw.gc_watermark,
            lastObservationSequence: raw.last_observation_sequence,
            retiredOperationRevisionWatermark:
                raw.retired_operation_revision_watermark,
            tombstoneCount: raw.tombstone_count,
            deviceInstanceGeneration:
                raw.device_instance_generation,
            observationRegistrationGeneration:
                raw.observation_registration_generation,
            currentOperation: raw.has_current_operation == 1
                ? operation(from: raw.current_operation)
                : nil
        )
    }

    private static func uuid(from raw: osata_uuid_t) -> UUID {
        var bytes: uuid_t = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        var high = raw.high.bigEndian
        var low = raw.low.bigEndian
        withUnsafeMutableBytes(of: &bytes) { destination in
            withUnsafeBytes(of: &high) { source in
                for index in source.indices {
                    destination[index] = source[index]
                }
            }
            withUnsafeBytes(of: &low) { source in
                for index in source.indices {
                    destination[MemoryLayout<UInt64>.size + index] =
                        source[index]
                }
            }
        }
        return UUID(uuid: bytes)
    }

    private static func dispositionRawValue(
        _ disposition: WebRTCIOSAudioCategoryObservationDisposition
    ) -> UInt32 {
        switch disposition {
        case .unrelated:
            OSATA_OBSERVATION_UNRELATED
        case .trackedPolicyMismatch:
            OSATA_OBSERVATION_TRACKED_POLICY_MISMATCH
        case .expectedUncorrelatedTransaction:
            OSATA_OBSERVATION_EXPECTED_UNCORRELATED_TRANSACTION
        case .expectedCurrentAppOperation:
            OSATA_OBSERVATION_EXPECTED_CURRENT_APP_OPERATION
        case .expectedRetiredAppOperation:
            OSATA_OBSERVATION_EXPECTED_RETIRED_APP_OPERATION
        }
    }

    private static func transactionStateRawValue(
        _ state: WebRTCIOSAudioCategoryTransactionState
    ) -> UInt32 {
        switch state {
        case .none:
            OSATA_TRANSACTION_STATE_NONE
        case .pending:
            OSATA_TRANSACTION_STATE_PENDING
        case .prepared:
            OSATA_TRANSACTION_STATE_PREPARED
        case .starting:
            OSATA_TRANSACTION_STATE_STARTING
        case .consumed:
            OSATA_TRANSACTION_STATE_CONSUMED
        case .rejected:
            OSATA_TRANSACTION_STATE_REJECTED
        }
    }

    private static func rejection(
        from raw: UInt32
    ) -> AudioTransactionRejection? {
        switch raw {
        case OSATA_REJECTION_STALE_REVISION:
            .staleRevision
        case OSATA_REJECTION_STALE_AUTHORITY:
            .staleAuthority
        case OSATA_REJECTION_STALE_OPERATION:
            .staleOperation
        case OSATA_REJECTION_DUPLICATE:
            .duplicate
        case OSATA_REJECTION_INVALID_INPUT:
            .invalidInput
        case OSATA_REJECTION_TARGET_MISMATCH:
            .targetMismatch
        case OSATA_REJECTION_BLOCKER_NOT_ALLOWED:
            .blockerNotAllowed
        case OSATA_REJECTION_NO_CURRENT_OPERATION:
            .noCurrentOperation
        case OSATA_REJECTION_CAPACITY_EXCEEDED:
            .capacityExceeded
        case OSATA_REJECTION_BLOCKER_REQUIRED:
            .blockerRequired
        case OSATA_REJECTION_COUNTER_EXHAUSTED:
            .counterExhausted
        default:
            nil
        }
    }

    private static func ignoreReason(
        from raw: UInt32
    ) -> AudioTransactionIgnoreReason? {
        switch raw {
        case OSATA_IGNORE_EXACT_DUPLICATE:
            .exactDuplicate
        case OSATA_IGNORE_CURRENT_OPERATION_ALREADY_TERMINAL:
            .currentOperationAlreadyTerminal
        case OSATA_IGNORE_RETIRED_OPERATION:
            .retiredOperation
        case OSATA_IGNORE_WATERMARK_RETIRED_OPERATION:
            .watermarkRetiredOperation
        case OSATA_IGNORE_STALE_DEVICE_GENERATION:
            .staleDeviceGeneration
        default:
            nil
        }
    }

    private static func runtimeFailure(
        from raw: UInt32
    ) -> AudioTransactionRuntimeFailure {
        switch raw {
        case OSATA_RUNTIME_NULL_POINTER:
            .nullPointer
        case OSATA_RUNTIME_POISONED:
            .poisoned
        default:
            .unknown(raw)
        }
    }
}
#endif
