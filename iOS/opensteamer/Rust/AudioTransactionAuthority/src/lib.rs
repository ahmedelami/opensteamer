//! Pure authority reducer for iOS audio-policy transactions.
//!
//! Native callbacks may be delayed, duplicated, or delivered after a newer lifecycle boundary.
//! This reducer makes those races explicit. An operation completes only after both its exact
//! native terminal receipt and its exact proof receipt succeed. An `AVAudioSession` observation is
//! evidence only; it can request proof or fail closed, but it can never grant authority.

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard};

pub const ABI_VERSION: u32 = 1;
pub const MAX_TOMBSTONES: usize = 64;

const fn sequence_cutoff_covers(cutoff: u64, required_sequence: u64) -> bool {
    cutoff >= required_sequence
}

#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
#[repr(C)]
pub struct OperationId {
    pub high: u64,
    pub low: u64,
}

impl OperationId {
    #[must_use]
    pub const fn is_valid(self) -> bool {
        self.high != 0 || self.low != 0
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct Target {
    pub category: u32,
    pub mode: u32,
    pub options: u64,
    pub route_sharing_policy: i64,
    pub input_required: u32,
    pub reserved: u32,
}

impl Target {
    pub const CATEGORY_PLAYBACK: u32 = 1;
    pub const CATEGORY_PLAY_AND_RECORD: u32 = 2;
    pub const MODE_DEFAULT: u32 = 1;

    #[must_use]
    pub const fn is_valid(self) -> bool {
        matches!(
            self.category,
            Self::CATEGORY_PLAYBACK | Self::CATEGORY_PLAY_AND_RECORD
        ) && self.mode == Self::MODE_DEFAULT
            && matches!(self.input_required, 0 | 1)
            && self.reserved == 0
            && (self.category != Self::CATEGORY_PLAY_AND_RECORD || self.input_required == 1)
            && (self.category != Self::CATEGORY_PLAYBACK || self.input_required == 0)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct OperationReceipt {
    pub operation_id: OperationId,
    pub operation_revision: u64,
    pub authority_epoch: u64,
}

impl OperationReceipt {
    #[must_use]
    pub const fn is_valid(self) -> bool {
        self.operation_id.is_valid() && self.operation_revision != 0 && self.authority_epoch != 0
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct BoundaryReceipt {
    pub reducer_revision: u64,
    pub authority_epoch: u64,
    pub has_blocker: u32,
    pub reserved: u32,
    pub blocker: OperationReceipt,
}

impl BoundaryReceipt {
    #[must_use]
    pub const fn blocker(self) -> Option<OperationReceipt> {
        if self.has_blocker == 1 {
            Some(self.blocker)
        } else {
            None
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct ProofReceipt {
    pub operation: OperationReceipt,
    pub proof_revision: u64,
}

/// Immutable terminal result from the one-shot native recovery authorization.
///
/// The native bridge publishes all fields before its terminal-generation release fence; Swift
/// copies them only after the matching acquire read.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct NativeRecoveryReceipt {
    pub operation: OperationReceipt,
    pub authorization_generation: u64,
    pub terminal_generation: u64,
    pub outcome: u32,
    pub policy_matches_requested_target: u32,
}

/// Immutable proof that the native observation queue drained one exact retired app operation.
///
/// Native detaches the matching tag while holding its ingress lock, captures the cutoff and
/// generations, then invokes the callback from a barrier behind every earlier category-observation
/// callback. This receipt is GC-only and can never authorize an operation.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct NativeDrainReceipt {
    pub operation: OperationReceipt,
    pub app_operation_tag_generation: u64,
    pub native_transaction_identifier: u64,
    pub transaction_configuration_generation: u64,
    pub system_audio_generation: u64,
    pub notification_sequence_watermark: u64,
    pub observation_registration_generation: u64,
    pub drain_generation: u64,
    pub device_instance_generation: u64,
    pub binding_state: u32,
    pub ingress_in_flight_count: u32,
    pub reserved0: u32,
    pub reserved1: u32,
}

impl NativeDrainReceipt {
    pub const BINDING_STATE_STAGED: u32 = 1;
    pub const BINDING_STATE_BOUND: u32 = 2;

    const fn is_canonical(self) -> bool {
        self.operation.is_valid()
            && self.app_operation_tag_generation != 0
            && self.system_audio_generation != 0
            && self.observation_registration_generation != 0
            && self.drain_generation != 0
            && self.device_instance_generation != 0
            && self.ingress_in_flight_count == 0
            && self.reserved0 == 0
            && self.reserved1 == 0
            && match self.binding_state {
                Self::BINDING_STATE_STAGED => self.native_transaction_identifier == 0,
                Self::BINDING_STATE_BOUND => {
                    self.native_transaction_identifier != 0
                        && self.transaction_configuration_generation != 0
                }
                _ => false,
            }
    }

    fn matches_observation(self, observation: NativeObservationReceipt) -> bool {
        self.binding_state == Self::BINDING_STATE_BOUND
            && self.operation == observation.app_operation
            && self.app_operation_tag_generation == observation.app_operation_tag_generation
            && self.device_instance_generation == observation.device_instance_generation
            && self.native_transaction_identifier == observation.native_transaction_identifier
            && self.transaction_configuration_generation
                == observation.transaction_configuration_generation
            && self.system_audio_generation == observation.transaction_system_audio_generation
            && self.notification_sequence_watermark >= observation.notification_sequence
    }
}

/// Immutable native category observation copied before crossing the actor/event boundary.
///
/// The app-operation receipt originates in a tag staged before native work starts. The reducer
/// never manufactures it from the target tuple or whichever operation happens to be current when
/// the observation is delivered.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct NativeObservationReceipt {
    pub app_operation: OperationReceipt,
    pub app_operation_tag_generation: u64,
    pub device_instance_generation: u64,
    pub native_transaction_identifier: u64,
    pub notification_sequence: u64,
    pub transaction_observer_sequence_baseline: u64,
    pub transaction_configuration_generation: u64,
    pub observed_configuration_generation: u64,
    pub transaction_system_audio_generation: u64,
    pub observed_system_audio_generation: u64,
    pub observed_at_nanoseconds: u64,
    pub transaction_deadline_nanoseconds: u64,
    pub disposition: u32,
    pub transaction_state_at_ingress: u32,
    pub has_app_operation: u32,
    pub policy_tuple_is_exact: u32,
    pub transaction_evidence_is_exact: u32,
    pub input_required: u32,
    pub reserved: u32,
    pub alignment_reserved: u32,
    pub expected_target: Target,
    pub observed_target: Target,
}

impl NativeObservationReceipt {
    pub const DISPOSITION_UNRELATED: u32 = 0;
    pub const DISPOSITION_TRACKED_POLICY_MISMATCH: u32 = 1;
    pub const DISPOSITION_EXPECTED_UNCORRELATED_TRANSACTION: u32 = 2;
    pub const DISPOSITION_EXPECTED_CURRENT_APP_OPERATION: u32 = 3;
    pub const DISPOSITION_EXPECTED_RETIRED_APP_OPERATION: u32 = 4;

    pub const TRANSACTION_STATE_NONE: u32 = 0;
    pub const TRANSACTION_STATE_PENDING: u32 = 1;
    pub const TRANSACTION_STATE_PREPARED: u32 = 2;
    pub const TRANSACTION_STATE_STARTING: u32 = 3;
    pub const TRANSACTION_STATE_CONSUMED: u32 = 4;
    pub const TRANSACTION_STATE_REJECTED: u32 = 5;

    fn has_structurally_exact_evidence(self) -> bool {
        self.has_app_operation == 1
            && self.app_operation.is_valid()
            && self.app_operation_tag_generation != 0
            && self.device_instance_generation != 0
            && self.native_transaction_identifier != 0
            && self.notification_sequence != 0
            && self.notification_sequence > self.transaction_observer_sequence_baseline
            && self.transaction_configuration_generation != 0
            && self.transaction_configuration_generation == self.observed_configuration_generation
            && self.transaction_system_audio_generation != 0
            && self.transaction_system_audio_generation == self.observed_system_audio_generation
            && self.observed_at_nanoseconds != 0
            && self.transaction_deadline_nanoseconds != 0
            && self.observed_at_nanoseconds <= self.transaction_deadline_nanoseconds
            && matches!(
                self.transaction_state_at_ingress,
                Self::TRANSACTION_STATE_PENDING
                    | Self::TRANSACTION_STATE_PREPARED
                    | Self::TRANSACTION_STATE_STARTING
                    | Self::TRANSACTION_STATE_CONSUMED
                    | Self::TRANSACTION_STATE_REJECTED
            )
            && self.policy_tuple_is_exact == 1
            && self.transaction_evidence_is_exact == 1
            && matches!(self.input_required, 0 | 1)
            && self.reserved == 0
            && self.alignment_reserved == 0
            && self.expected_target.is_valid()
            && self.observed_target.is_valid()
            && self.expected_target == self.observed_target
            && self.expected_target.input_required == self.input_required
    }

    /// A notification may be delivered more than once for the same immutable native
    /// transaction. A later sequence/time is harmless only when every other provenance and
    /// evidence field still names the exact same transaction and accepted policy.
    fn is_later_observation_of(self, earlier: Self) -> bool {
        self.has_structurally_exact_evidence()
            && earlier.has_structurally_exact_evidence()
            && self.app_operation == earlier.app_operation
            && self.app_operation_tag_generation == earlier.app_operation_tag_generation
            && self.device_instance_generation == earlier.device_instance_generation
            && self.native_transaction_identifier == earlier.native_transaction_identifier
            && self.notification_sequence > earlier.notification_sequence
            && self.transaction_observer_sequence_baseline
                == earlier.transaction_observer_sequence_baseline
            && self.transaction_configuration_generation
                == earlier.transaction_configuration_generation
            && self.observed_configuration_generation == earlier.observed_configuration_generation
            && self.transaction_system_audio_generation
                == earlier.transaction_system_audio_generation
            && self.observed_system_audio_generation == earlier.observed_system_audio_generation
            && self.observed_at_nanoseconds >= earlier.observed_at_nanoseconds
            && self.transaction_deadline_nanoseconds == earlier.transaction_deadline_nanoseconds
            && self.disposition == Self::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION
            && earlier.disposition == Self::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION
            && self.transaction_state_at_ingress != Self::TRANSACTION_STATE_REJECTED
            && earlier.transaction_state_at_ingress != Self::TRANSACTION_STATE_REJECTED
            && self.has_app_operation == earlier.has_app_operation
            && self.policy_tuple_is_exact == earlier.policy_tuple_is_exact
            && self.transaction_evidence_is_exact == earlier.transaction_evidence_is_exact
            && self.input_required == earlier.input_required
            && self.reserved == earlier.reserved
            && self.alignment_reserved == earlier.alignment_reserved
            && self.expected_target == earlier.expected_target
            && self.observed_target == earlier.observed_target
    }
}

/// Immutable proof that one native device receipt stream has been fully torn down.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct NativeDeviceTeardownReceipt {
    pub device_instance_generation: u64,
    pub observation_registration_generation: u64,
    pub notification_sequence_watermark: u64,
    pub teardown_generation: u64,
    pub ingress_in_flight_count: u32,
    pub reserved0: u32,
    pub reserved1: u32,
    pub reserved2: u32,
}

impl NativeDeviceTeardownReceipt {
    const fn is_canonical(self) -> bool {
        self.device_instance_generation != 0
            && self.observation_registration_generation != 0
            && self.teardown_generation != 0
            && self.ingress_in_flight_count == 0
            && self.reserved0 == 0
            && self.reserved1 == 0
            && self.reserved2 == 0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum NativeOutcome {
    Accepted = 1,
    Rejected = 2,
    Revoked = 3,
}

impl TryFrom<u32> for NativeOutcome {
    type Error = Rejection;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Accepted),
            2 => Ok(Self::Rejected),
            3 => Ok(Self::Revoked),
            _ => Err(Rejection::InvalidInput),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum ProofOutcome {
    Accepted = 1,
    Rejected = 2,
}

impl TryFrom<u32> for ProofOutcome {
    type Error = Rejection;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Accepted),
            2 => Ok(Self::Rejected),
            _ => Err(Rejection::InvalidInput),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Rejection {
    StaleRevision = 1,
    StaleAuthority = 2,
    StaleOperation = 3,
    Duplicate = 4,
    InvalidInput = 5,
    TargetMismatch = 6,
    BlockerNotAllowed = 7,
    NoCurrentOperation = 8,
    CapacityExceeded = 9,
    BlockerRequired = 10,
    CounterExhausted = 11,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum IgnoreReason {
    ExactDuplicate = 1,
    CurrentOperationAlreadyTerminal = 2,
    RetiredOperation = 3,
    // Historical ABI name: this applies only to an exact retained receipt, never a revision range.
    WatermarkRetiredOperation = 4,
    StaleDeviceGeneration = 5,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Decision {
    Armed {
        operation: OperationReceipt,
        proof: ProofReceipt,
        predecessor: Option<OperationReceipt>,
    },
    AbortedUnpublished(OperationReceipt),
    DeviceBound,
    DeviceRetired(Option<OperationReceipt>),
    BoundaryApplied(BoundaryReceipt),
    NativeAcknowledged(OperationReceipt),
    ObservationAccepted {
        operation: OperationReceipt,
        proof: ProofReceipt,
    },
    WaitingForNativeAcknowledgement(OperationReceipt),
    Completed(OperationReceipt),
    FailedClosed(Option<OperationReceipt>),
    Ignored {
        reason: IgnoreReason,
        operation: Option<OperationReceipt>,
        blocker: Option<OperationReceipt>,
    },
    GarbageCollected(OperationReceipt),
    Rejected(Rejection),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct Snapshot {
    pub abi_version: u32,
    pub has_current_operation: u32,
    pub reducer_revision: u64,
    pub authority_epoch: u64,
    pub gc_watermark: u64,
    pub last_observation_sequence: u64,
    /// Diagnostic high-water mark only. Exact retired membership is tracked by full receipts.
    pub retired_operation_revision_watermark: u64,
    pub tombstone_count: u64,
    pub device_instance_generation: u64,
    pub observation_registration_generation: u64,
    pub current_operation: OperationReceipt,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OperationPhase {
    Pending,
    Completed,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Operation {
    receipt: OperationReceipt,
    proof: ProofReceipt,
    target: Target,
    observation_baseline: u64,
    device_instance_generation: u64,
    observation_registration_generation: u64,
    native_receipt: Option<NativeRecoveryReceipt>,
    native_outcome: Option<NativeOutcome>,
    proof_outcome: Option<ProofOutcome>,
    observation: Option<NativeObservationReceipt>,
    phase: OperationPhase,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Tombstone {
    receipt: OperationReceipt,
    target: Target,
    terminal_observation_ceiling: u64,
    observation: Option<NativeObservationReceipt>,
    device_instance_generation: u64,
    observation_registration_generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConsumedDrain {
    receipt: NativeDrainReceipt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Boundary {
    receipt: BoundaryReceipt,
    blocker_target: Option<Target>,
}

/// Single-writer deterministic reducer. The FFI wrapper additionally serializes calls with a
/// mutex so an accidental cross-thread call cannot create a data race.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorityReducer {
    reducer_revision: u64,
    authority_epoch: u64,
    next_operation_revision: u64,
    next_proof_revision: u64,
    gc_watermark: u64,
    last_observation_sequence: u64,
    retired_operation_revision_watermark: u64,
    device_instance_generation: u64,
    observation_registration_generation: u64,
    maximum_device_instance_generation: u64,
    maximum_device_teardown_generation: u64,
    current: Option<Operation>,
    tombstones: VecDeque<Tombstone>,
    retired_operations: VecDeque<OperationReceipt>,
    consumed_drains: VecDeque<ConsumedDrain>,
    last_boundary: Option<Boundary>,
    last_device_teardown: Option<NativeDeviceTeardownReceipt>,
}

impl AuthorityReducer {
    /// Creates an empty reducer at a nonzero authority epoch.
    ///
    /// # Errors
    ///
    /// Returns [`Rejection::InvalidInput`] when the initial epoch is zero.
    pub const fn new(initial_authority_epoch: u64) -> Result<Self, Rejection> {
        if initial_authority_epoch == 0 {
            return Err(Rejection::InvalidInput);
        }
        Ok(Self {
            reducer_revision: 1,
            authority_epoch: initial_authority_epoch,
            next_operation_revision: 1,
            next_proof_revision: 1,
            gc_watermark: 0,
            last_observation_sequence: 0,
            retired_operation_revision_watermark: 0,
            device_instance_generation: 0,
            observation_registration_generation: 0,
            maximum_device_instance_generation: 0,
            maximum_device_teardown_generation: 0,
            current: None,
            tombstones: VecDeque::new(),
            retired_operations: VecDeque::new(),
            consumed_drains: VecDeque::new(),
            last_boundary: None,
            last_device_teardown: None,
        })
    }

    #[must_use]
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            abi_version: ABI_VERSION,
            has_current_operation: u32::from(self.current.is_some()),
            reducer_revision: self.reducer_revision,
            authority_epoch: self.authority_epoch,
            gc_watermark: self.gc_watermark,
            last_observation_sequence: self.last_observation_sequence,
            retired_operation_revision_watermark: self.retired_operation_revision_watermark,
            tombstone_count: u64::try_from(self.tombstones.len()).unwrap_or(u64::MAX),
            device_instance_generation: self.device_instance_generation,
            observation_registration_generation: self.observation_registration_generation,
            current_operation: self
                .current
                .as_ref()
                .map_or_else(OperationReceipt::default, |operation| operation.receipt),
        }
    }

    pub fn bind_device(
        &mut self,
        expected_reducer_revision: u64,
        device_instance_generation: u64,
        observation_registration_generation: u64,
    ) -> Decision {
        if expected_reducer_revision != self.reducer_revision {
            return Decision::Rejected(Rejection::StaleRevision);
        }
        if device_instance_generation == 0 || observation_registration_generation == 0 {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        if self.device_instance_generation != 0 {
            return if self.device_instance_generation == device_instance_generation
                && self.observation_registration_generation == observation_registration_generation
            {
                Decision::Ignored {
                    reason: IgnoreReason::ExactDuplicate,
                    operation: self.current.as_ref().map(|current| current.receipt),
                    blocker: None,
                }
            } else {
                Decision::Rejected(Rejection::Duplicate)
            };
        }
        if self.current.is_some() || !self.tombstones.is_empty() {
            return Decision::Rejected(Rejection::StaleOperation);
        }
        if device_instance_generation <= self.maximum_device_instance_generation {
            return Decision::Rejected(Rejection::StaleAuthority);
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        self.device_instance_generation = device_instance_generation;
        self.observation_registration_generation = observation_registration_generation;
        self.maximum_device_instance_generation = device_instance_generation;
        self.gc_watermark = 0;
        self.last_observation_sequence = 0;
        self.reducer_revision = next_revision;
        Decision::DeviceBound
    }

    pub fn retire_device(
        &mut self,
        expected_reducer_revision: u64,
        receipt: NativeDeviceTeardownReceipt,
    ) -> Decision {
        if expected_reducer_revision != self.reducer_revision {
            return Decision::Rejected(Rejection::StaleRevision);
        }
        if !receipt.is_canonical() {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        if let Some(previous) = self.last_device_teardown {
            if previous == receipt {
                return Decision::Ignored {
                    reason: IgnoreReason::ExactDuplicate,
                    operation: None,
                    blocker: None,
                };
            }
            if previous.device_instance_generation == receipt.device_instance_generation {
                return Decision::Rejected(Rejection::Duplicate);
            }
        }
        if receipt.device_instance_generation != self.device_instance_generation {
            return if self.device_generation_is_retired(receipt.device_instance_generation) {
                self.ignore_stale_device(None)
            } else {
                Decision::Rejected(Rejection::StaleAuthority)
            };
        }
        if receipt.observation_registration_generation != self.observation_registration_generation {
            return Decision::Rejected(Rejection::StaleAuthority);
        }
        if receipt.teardown_generation <= self.maximum_device_teardown_generation
            || receipt.notification_sequence_watermark < self.last_observation_sequence
            || self.current.as_ref().is_some_and(|current| {
                current.device_instance_generation != self.device_instance_generation
                    || current.observation_registration_generation
                        != self.observation_registration_generation
                    || !sequence_cutoff_covers(
                        receipt.notification_sequence_watermark,
                        current.observation_baseline,
                    )
            })
            || self.tombstones.iter().any(|tombstone| {
                tombstone.device_instance_generation != self.device_instance_generation
                    || tombstone.observation_registration_generation
                        != self.observation_registration_generation
                    || !sequence_cutoff_covers(
                        receipt.notification_sequence_watermark,
                        tombstone.terminal_observation_ceiling,
                    )
            })
        {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        let Some(next_epoch) = self.authority_epoch.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let retired_current = self.current.take().map(|operation| operation.receipt);
        self.retired_operation_revision_watermark = self.tombstones.iter().fold(
            self.retired_operation_revision_watermark,
            |watermark, tombstone| watermark.max(tombstone.receipt.operation_revision),
        );
        if let Some(operation) = retired_current {
            self.retired_operation_revision_watermark = self
                .retired_operation_revision_watermark
                .max(operation.operation_revision);
            self.retain_retired_operation(operation);
        }
        while let Some(tombstone) = self.tombstones.pop_front() {
            self.retain_retired_operation(tombstone.receipt);
        }
        self.consumed_drains.clear();
        self.last_boundary = None;
        self.last_device_teardown = Some(receipt);
        self.maximum_device_teardown_generation = receipt.teardown_generation;
        self.device_instance_generation = 0;
        self.observation_registration_generation = 0;
        self.gc_watermark = 0;
        self.last_observation_sequence = 0;
        self.authority_epoch = next_epoch;
        self.reducer_revision = next_revision;
        Decision::DeviceRetired(retired_current)
    }

    pub fn arm(
        &mut self,
        expected_reducer_revision: u64,
        observation_head: u64,
        operation_id: OperationId,
        target: Target,
    ) -> Decision {
        if let Err(rejection) = self.validate_arm(
            expected_reducer_revision,
            observation_head,
            operation_id,
            target,
        ) {
            return Decision::Rejected(rejection);
        }
        self.arm_validated(operation_id, target, observation_head, None)
    }

    pub fn apply_boundary(
        &mut self,
        expected_reducer_revision: u64,
        observation_head: u64,
    ) -> Decision {
        if expected_reducer_revision != self.reducer_revision {
            return Decision::Rejected(Rejection::StaleRevision);
        }
        if self.device_instance_generation == 0 || self.observation_registration_generation == 0 {
            return Decision::Rejected(Rejection::StaleAuthority);
        }
        if !self.observation_head_is_valid(observation_head) {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        if self.current.is_some() && self.tombstones.len() == MAX_TOMBSTONES {
            return Decision::Rejected(Rejection::CapacityExceeded);
        }
        let Some(next_epoch) = self.authority_epoch.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let retired = self.current.take();
        let (has_blocker, blocker, blocker_target) = if let Some(operation) = retired {
            let receipt = operation.receipt;
            let target = operation.target;
            self.tombstones.push_back(Tombstone {
                receipt,
                target,
                terminal_observation_ceiling: observation_head,
                observation: operation.observation,
                device_instance_generation: operation.device_instance_generation,
                observation_registration_generation: operation.observation_registration_generation,
            });
            (1, receipt, Some(target))
        } else {
            (0, OperationReceipt::default(), None)
        };

        self.authority_epoch = next_epoch;
        self.reducer_revision = next_revision;
        let receipt = BoundaryReceipt {
            reducer_revision: next_revision,
            authority_epoch: next_epoch,
            has_blocker,
            reserved: 0,
            blocker,
        };
        self.last_boundary = Some(Boundary {
            receipt,
            blocker_target,
        });
        Decision::BoundaryApplied(receipt)
    }

    /// Removes an operation only when native staging rejected it before any native effect could
    /// begin. Rotating the authority epoch fences delayed receipts without consuming tombstone
    /// capacity. Callers must not use this after native staging returned a nonzero generation.
    pub fn abort_unpublished(
        &mut self,
        expected_reducer_revision: u64,
        operation_receipt: OperationReceipt,
    ) -> Decision {
        if expected_reducer_revision != self.reducer_revision {
            return Decision::Rejected(Rejection::StaleRevision);
        }
        let Some(current) = self.current.as_ref() else {
            return Decision::Rejected(Rejection::NoCurrentOperation);
        };
        if current.receipt != operation_receipt {
            return Decision::Rejected(Rejection::StaleOperation);
        }
        if current.phase != OperationPhase::Pending
            || current.native_receipt.is_some()
            || current.proof_outcome.is_some()
            || current.observation.is_some()
        {
            return Decision::Rejected(Rejection::StaleOperation);
        }
        let Some(next_epoch) = self.authority_epoch.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        self.current = None;
        self.authority_epoch = next_epoch;
        self.reducer_revision = next_revision;
        self.last_boundary = None;
        Decision::AbortedUnpublished(operation_receipt)
    }

    pub fn arm_successor(
        &mut self,
        boundary_receipt: BoundaryReceipt,
        observation_head: u64,
        operation_id: OperationId,
        target: Target,
    ) -> Decision {
        let Some(boundary) = self.last_boundary.as_ref() else {
            return Decision::Rejected(Rejection::StaleRevision);
        };
        if boundary.receipt != boundary_receipt
            || boundary_receipt.reducer_revision != self.reducer_revision
            || boundary_receipt.authority_epoch != self.authority_epoch
        {
            return Decision::Rejected(Rejection::StaleRevision);
        }
        if let Err(rejection) = self.validate_arm(
            boundary_receipt.reducer_revision,
            observation_head,
            operation_id,
            target,
        ) {
            return Decision::Rejected(rejection);
        }

        let predecessor = match (boundary_receipt.blocker(), boundary.blocker_target) {
            (Some(blocker), Some(blocker_target)) if blocker_target == target => {
                let retained = self
                    .tombstones
                    .iter()
                    .any(|tombstone| tombstone.receipt == blocker && tombstone.target == target);
                if !retained {
                    return Decision::Rejected(Rejection::StaleOperation);
                }
                Some(blocker)
            }
            _ => None,
        };
        self.arm_validated(operation_id, target, observation_head, predecessor)
    }

    pub fn acknowledge_native(&mut self, receipt: NativeRecoveryReceipt) -> Decision {
        let Some(current) = self.current.as_ref() else {
            return self.ignore_or_reject_stale_operation(receipt.operation);
        };
        if current.receipt != receipt.operation {
            return self.ignore_or_reject_stale_operation(receipt.operation);
        }
        if let Some(existing) = current.native_receipt {
            return if existing == receipt {
                Decision::Ignored {
                    reason: IgnoreReason::ExactDuplicate,
                    operation: Some(receipt.operation),
                    blocker: None,
                }
            } else {
                self.fail_current_operation()
            };
        }
        if current.phase != OperationPhase::Pending {
            return Decision::Ignored {
                reason: IgnoreReason::CurrentOperationAlreadyTerminal,
                operation: Some(receipt.operation),
                blocker: None,
            };
        }
        let Ok(outcome) = NativeOutcome::try_from(receipt.outcome) else {
            return Decision::Rejected(Rejection::InvalidInput);
        };
        if receipt.authorization_generation == 0
            || receipt.terminal_generation != receipt.authorization_generation
            || !matches!(receipt.policy_matches_requested_target, 0 | 1)
        {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let Some(current) = self.current.as_mut() else {
            return Decision::Rejected(Rejection::NoCurrentOperation);
        };
        let accepted =
            outcome == NativeOutcome::Accepted && receipt.policy_matches_requested_target == 1;
        current.native_outcome = Some(if accepted {
            NativeOutcome::Accepted
        } else {
            NativeOutcome::Rejected
        });
        current.native_receipt = Some(receipt);
        self.reducer_revision = next_revision;
        if accepted {
            if current.proof_outcome == Some(ProofOutcome::Accepted) {
                current.phase = OperationPhase::Completed;
                Decision::Completed(receipt.operation)
            } else {
                Decision::NativeAcknowledged(receipt.operation)
            }
        } else {
            current.phase = OperationPhase::Failed;
            Decision::FailedClosed(Some(receipt.operation))
        }
    }

    pub fn observe(&mut self, receipt: NativeObservationReceipt) -> Decision {
        if receipt.device_instance_generation != 0
            && receipt.device_instance_generation != self.device_instance_generation
        {
            let operation = (receipt.has_app_operation == 1).then_some(receipt.app_operation);
            return if self.device_generation_is_retired(receipt.device_instance_generation) {
                self.ignore_stale_device(operation)
            } else if self.current.is_some() {
                self.fail_current_operation()
            } else {
                Decision::Rejected(Rejection::StaleAuthority)
            };
        }
        let Some(current) = self.current.as_ref() else {
            return if receipt.has_app_operation == 1 {
                self.ignore_or_fail_closed_stale_operation(receipt.app_operation)
            } else {
                Decision::FailedClosed(None)
            };
        };

        if receipt.has_app_operation == 1 && receipt.app_operation == current.receipt {
            if let Some(existing) = current.observation {
                return if existing == receipt || receipt.is_later_observation_of(existing) {
                    Decision::Ignored {
                        reason: IgnoreReason::ExactDuplicate,
                        operation: Some(current.receipt),
                        blocker: None,
                    }
                } else {
                    self.fail_current_operation()
                };
            }
            if current.phase != OperationPhase::Pending {
                return if receipt.has_structurally_exact_evidence()
                    && receipt.disposition
                        == NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION
                    && receipt.transaction_state_at_ingress
                        != NativeObservationReceipt::TRANSACTION_STATE_REJECTED
                {
                    Decision::Ignored {
                        reason: IgnoreReason::CurrentOperationAlreadyTerminal,
                        operation: Some(current.receipt),
                        blocker: None,
                    }
                } else {
                    self.fail_current_operation()
                };
            }
        }

        if receipt.disposition
            == NativeObservationReceipt::DISPOSITION_EXPECTED_RETIRED_APP_OPERATION
            && receipt.has_app_operation == 1
            && self.operation_is_exactly_retired(receipt.app_operation)
        {
            return Decision::Ignored {
                reason: if self.operation_is_retained(receipt.app_operation) {
                    IgnoreReason::RetiredOperation
                } else {
                    IgnoreReason::WatermarkRetiredOperation
                },
                operation: Some(current.receipt),
                blocker: Some(receipt.app_operation),
            };
        }

        if current.phase != OperationPhase::Pending
            || !receipt.has_structurally_exact_evidence()
            || receipt.disposition
                != NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION
            || receipt.transaction_state_at_ingress
                == NativeObservationReceipt::TRANSACTION_STATE_REJECTED
            || receipt.app_operation != current.receipt
            || receipt.device_instance_generation != current.device_instance_generation
            || receipt.expected_target != current.target
            || receipt.notification_sequence <= current.observation_baseline
            || receipt.notification_sequence <= self.last_observation_sequence
            || receipt.notification_sequence <= self.gc_watermark
        {
            return self.fail_current_operation();
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let Some(current) = self.current.as_mut() else {
            return Decision::Rejected(Rejection::NoCurrentOperation);
        };
        current.observation = Some(receipt);
        self.last_observation_sequence = receipt.notification_sequence;
        self.reducer_revision = next_revision;
        Decision::ObservationAccepted {
            operation: current.receipt,
            proof: current.proof,
        }
    }

    pub fn resolve_proof(
        &mut self,
        proof_receipt: ProofReceipt,
        outcome: ProofOutcome,
    ) -> Decision {
        let Some(current) = self.current.as_ref() else {
            return self.ignore_or_reject_stale_operation(proof_receipt.operation);
        };
        if current.receipt != proof_receipt.operation || current.proof != proof_receipt {
            return self.ignore_or_reject_stale_operation(proof_receipt.operation);
        }
        if let Some(existing) = current.proof_outcome {
            return if existing == outcome {
                Decision::Ignored {
                    reason: IgnoreReason::ExactDuplicate,
                    operation: Some(proof_receipt.operation),
                    blocker: None,
                }
            } else {
                self.fail_current_operation()
            };
        }
        if current.phase != OperationPhase::Pending {
            return Decision::Ignored {
                reason: IgnoreReason::CurrentOperationAlreadyTerminal,
                operation: Some(proof_receipt.operation),
                blocker: None,
            };
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let Some(current) = self.current.as_mut() else {
            return Decision::Rejected(Rejection::NoCurrentOperation);
        };
        current.proof_outcome = Some(outcome);
        self.reducer_revision = next_revision;
        match outcome {
            ProofOutcome::Accepted => {
                if current.native_outcome == Some(NativeOutcome::Accepted) {
                    current.phase = OperationPhase::Completed;
                    Decision::Completed(current.receipt)
                } else {
                    Decision::WaitingForNativeAcknowledgement(current.receipt)
                }
            }
            ProofOutcome::Rejected => {
                current.phase = OperationPhase::Failed;
                Decision::FailedClosed(Some(current.receipt))
            }
        }
    }

    pub fn collect_retired(&mut self, receipt: NativeDrainReceipt) -> Decision {
        if !receipt.is_canonical() {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        if receipt.device_instance_generation != self.device_instance_generation {
            return if self.device_generation_is_retired(receipt.device_instance_generation) {
                self.ignore_stale_device(Some(receipt.operation))
            } else {
                Decision::Rejected(Rejection::StaleAuthority)
            };
        }
        if receipt.observation_registration_generation != self.observation_registration_generation {
            return Decision::Rejected(Rejection::StaleAuthority);
        }
        if let Some(consumed) = self
            .consumed_drains
            .iter()
            .find(|consumed| consumed.receipt.operation == receipt.operation)
        {
            return if consumed.receipt == receipt {
                Decision::Ignored {
                    reason: IgnoreReason::ExactDuplicate,
                    operation: Some(receipt.operation),
                    blocker: None,
                }
            } else {
                Decision::Rejected(Rejection::Duplicate)
            };
        }
        if self.consumed_drains.iter().any(|consumed| {
            consumed.receipt.device_instance_generation == receipt.device_instance_generation
                && consumed.receipt.drain_generation == receipt.drain_generation
        }) {
            return Decision::Rejected(Rejection::Duplicate);
        }
        if self
            .current
            .as_ref()
            .is_some_and(|current| current.receipt == receipt.operation)
        {
            return Decision::Rejected(Rejection::StaleOperation);
        }

        let Some(index) = self
            .tombstones
            .iter()
            .position(|tombstone| tombstone.receipt == receipt.operation)
        else {
            return self.ignore_or_reject_stale_operation(receipt.operation);
        };
        let tombstone = &self.tombstones[index];
        if !sequence_cutoff_covers(
            receipt.notification_sequence_watermark,
            tombstone.terminal_observation_ceiling,
        ) || receipt.device_instance_generation != tombstone.device_instance_generation
            || receipt.observation_registration_generation
                != tombstone.observation_registration_generation
            || tombstone
                .observation
                .is_some_and(|observation| !receipt.matches_observation(observation))
        {
            return Decision::Rejected(Rejection::InvalidInput);
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };

        let Some(removed) = self.tombstones.remove(index) else {
            return Decision::Rejected(Rejection::StaleOperation);
        };
        if self.consumed_drains.len() == MAX_TOMBSTONES {
            self.consumed_drains.pop_front();
        }
        self.consumed_drains.push_back(ConsumedDrain { receipt });
        self.gc_watermark = self
            .gc_watermark
            .max(receipt.notification_sequence_watermark);
        self.last_observation_sequence = self
            .last_observation_sequence
            .max(receipt.notification_sequence_watermark);
        self.retired_operation_revision_watermark = self
            .retired_operation_revision_watermark
            .max(removed.receipt.operation_revision);
        self.retain_retired_operation(removed.receipt);
        self.reducer_revision = next_revision;
        Decision::GarbageCollected(removed.receipt)
    }

    fn validate_arm(
        &self,
        expected_reducer_revision: u64,
        observation_head: u64,
        operation_id: OperationId,
        target: Target,
    ) -> Result<(), Rejection> {
        if expected_reducer_revision != self.reducer_revision {
            return Err(Rejection::StaleRevision);
        }
        if self.device_instance_generation == 0 || self.observation_registration_generation == 0 {
            return Err(Rejection::StaleAuthority);
        }
        if self.current.is_some() {
            return Err(Rejection::StaleOperation);
        }
        if !operation_id.is_valid()
            || !target.is_valid()
            || !self.observation_head_is_valid(observation_head)
        {
            return Err(Rejection::InvalidInput);
        }
        if self
            .tombstones
            .iter()
            .any(|tombstone| tombstone.receipt.operation_id == operation_id)
        {
            return Err(Rejection::Duplicate);
        }
        if self.next_operation_revision == u64::MAX
            || self.next_proof_revision == u64::MAX
            || self.reducer_revision == u64::MAX
        {
            return Err(Rejection::CounterExhausted);
        }
        Ok(())
    }

    const fn arm_validated(
        &mut self,
        operation_id: OperationId,
        target: Target,
        observation_head: u64,
        predecessor: Option<OperationReceipt>,
    ) -> Decision {
        let receipt = OperationReceipt {
            operation_id,
            operation_revision: self.next_operation_revision,
            authority_epoch: self.authority_epoch,
        };
        let proof = ProofReceipt {
            operation: receipt,
            proof_revision: self.next_proof_revision,
        };
        self.next_operation_revision += 1;
        self.next_proof_revision += 1;
        self.reducer_revision += 1;
        self.current = Some(Operation {
            receipt,
            proof,
            target,
            observation_baseline: observation_head,
            device_instance_generation: self.device_instance_generation,
            observation_registration_generation: self.observation_registration_generation,
            native_receipt: None,
            native_outcome: None,
            proof_outcome: None,
            observation: None,
            phase: OperationPhase::Pending,
        });
        self.last_boundary = None;
        Decision::Armed {
            operation: receipt,
            proof,
            predecessor,
        }
    }

    const fn observation_head_is_valid(&self, observation_head: u64) -> bool {
        observation_head == self.last_observation_sequence && observation_head >= self.gc_watermark
    }

    fn operation_is_retained(&self, receipt: OperationReceipt) -> bool {
        self.tombstones
            .iter()
            .any(|tombstone| tombstone.receipt == receipt)
    }

    fn operation_is_exactly_retired(&self, receipt: OperationReceipt) -> bool {
        self.operation_is_retained(receipt)
            || self
                .retired_operations
                .iter()
                .any(|retired| *retired == receipt)
    }

    fn ignore_or_reject_stale_operation(&self, receipt: OperationReceipt) -> Decision {
        if self.operation_is_exactly_retired(receipt) {
            Decision::Ignored {
                reason: if self.operation_is_retained(receipt) {
                    IgnoreReason::RetiredOperation
                } else {
                    IgnoreReason::WatermarkRetiredOperation
                },
                operation: Some(receipt),
                blocker: None,
            }
        } else {
            Decision::Rejected(Rejection::StaleOperation)
        }
    }

    fn ignore_or_fail_closed_stale_operation(&mut self, receipt: OperationReceipt) -> Decision {
        if self.operation_is_exactly_retired(receipt) {
            self.ignore_or_reject_stale_operation(receipt)
        } else if self.current.is_some() {
            self.fail_current_operation()
        } else {
            Decision::FailedClosed(None)
        }
    }

    fn ignore_stale_device(&self, receipt: Option<OperationReceipt>) -> Decision {
        Decision::Ignored {
            reason: IgnoreReason::StaleDeviceGeneration,
            operation: self.current.as_ref().map(|current| current.receipt),
            blocker: receipt,
        }
    }

    const fn device_generation_is_retired(&self, generation: u64) -> bool {
        generation != 0
            && generation != self.device_instance_generation
            && generation <= self.maximum_device_instance_generation
    }

    fn retain_retired_operation(&mut self, receipt: OperationReceipt) {
        if self
            .retired_operations
            .iter()
            .any(|retired| *retired == receipt)
        {
            return;
        }
        if self.retired_operations.len() == MAX_TOMBSTONES {
            self.retired_operations.pop_front();
        }
        self.retired_operations.push_back(receipt);
    }

    fn fail_current_operation(&mut self) -> Decision {
        let Some(current) = self.current.as_mut() else {
            return Decision::FailedClosed(None);
        };
        if current.phase == OperationPhase::Failed {
            return Decision::Ignored {
                reason: IgnoreReason::CurrentOperationAlreadyTerminal,
                operation: Some(current.receipt),
                blocker: None,
            };
        }
        let Some(next_revision) = self.reducer_revision.checked_add(1) else {
            return Decision::Rejected(Rejection::CounterExhausted);
        };
        current.phase = OperationPhase::Failed;
        self.reducer_revision = next_revision;
        Decision::FailedClosed(Some(current.receipt))
    }
}

pub const RUNTIME_OK: u32 = 0;
pub const RUNTIME_NULL_POINTER: u32 = 1;
// Runtime value 2 is reserved. Release artifacts use panic=abort and never claim recovery.
pub const RUNTIME_POISONED: u32 = 3;

pub const DECISION_REJECTED: u32 = 0;
pub const DECISION_ARMED: u32 = 1;
pub const DECISION_BOUNDARY_APPLIED: u32 = 2;
pub const DECISION_NATIVE_ACKNOWLEDGED: u32 = 3;
pub const DECISION_OBSERVATION_ACCEPTED: u32 = 4;
pub const DECISION_ABORTED_UNPUBLISHED: u32 = 5;
pub const DECISION_WAITING_FOR_NATIVE_ACKNOWLEDGEMENT: u32 = 6;
pub const DECISION_COMPLETED: u32 = 7;
pub const DECISION_FAILED_CLOSED: u32 = 8;
pub const DECISION_GARBAGE_COLLECTED: u32 = 9;
pub const DECISION_IGNORED: u32 = 10;
pub const DECISION_DEVICE_BOUND: u32 = 11;
pub const DECISION_DEVICE_RETIRED: u32 = 12;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
pub struct FfiDecision {
    pub abi_version: u32,
    pub kind: u32,
    pub rejection: u32,
    pub ignore_reason: u32,
    pub reducer_revision: u64,
    pub authority_epoch: u64,
    pub has_operation: u32,
    pub has_boundary: u32,
    pub has_proof: u32,
    pub has_blocker: u32,
    pub operation: OperationReceipt,
    pub boundary: BoundaryReceipt,
    pub proof: ProofReceipt,
    pub blocker: OperationReceipt,
}

impl FfiDecision {
    fn from_decision(decision: Decision, snapshot: Snapshot) -> Self {
        let mut ffi = Self {
            abi_version: ABI_VERSION,
            reducer_revision: snapshot.reducer_revision,
            authority_epoch: snapshot.authority_epoch,
            ..Self::default()
        };
        match decision {
            Decision::Armed {
                operation,
                proof,
                predecessor,
            } => {
                ffi.kind = DECISION_ARMED;
                ffi.has_operation = 1;
                ffi.has_proof = 1;
                ffi.operation = operation;
                ffi.proof = proof;
                if let Some(predecessor) = predecessor {
                    ffi.has_blocker = 1;
                    ffi.blocker = predecessor;
                }
            }
            Decision::AbortedUnpublished(operation) => {
                ffi.kind = DECISION_ABORTED_UNPUBLISHED;
                ffi.has_operation = 1;
                ffi.operation = operation;
            }
            Decision::DeviceBound => {
                ffi.kind = DECISION_DEVICE_BOUND;
            }
            Decision::DeviceRetired(operation) => {
                ffi.kind = DECISION_DEVICE_RETIRED;
                if let Some(operation) = operation {
                    ffi.has_operation = 1;
                    ffi.operation = operation;
                }
            }
            Decision::BoundaryApplied(boundary) => {
                ffi.kind = DECISION_BOUNDARY_APPLIED;
                ffi.has_boundary = 1;
                ffi.has_blocker = boundary.has_blocker;
                ffi.boundary = boundary;
                ffi.blocker = boundary.blocker;
            }
            Decision::NativeAcknowledged(operation) => {
                ffi.kind = DECISION_NATIVE_ACKNOWLEDGED;
                ffi.has_operation = 1;
                ffi.operation = operation;
            }
            Decision::ObservationAccepted { operation, proof } => {
                ffi.kind = DECISION_OBSERVATION_ACCEPTED;
                ffi.has_operation = 1;
                ffi.has_proof = 1;
                ffi.operation = operation;
                ffi.proof = proof;
            }
            Decision::WaitingForNativeAcknowledgement(operation) => {
                ffi.kind = DECISION_WAITING_FOR_NATIVE_ACKNOWLEDGEMENT;
                ffi.has_operation = 1;
                ffi.operation = operation;
            }
            Decision::Completed(operation) => {
                ffi.kind = DECISION_COMPLETED;
                ffi.has_operation = 1;
                ffi.operation = operation;
            }
            Decision::FailedClosed(operation) => {
                ffi.kind = DECISION_FAILED_CLOSED;
                if let Some(operation) = operation {
                    ffi.has_operation = 1;
                    ffi.operation = operation;
                }
            }
            Decision::Ignored {
                reason,
                operation,
                blocker,
            } => {
                ffi.kind = DECISION_IGNORED;
                ffi.ignore_reason = reason as u32;
                if let Some(operation) = operation {
                    ffi.has_operation = 1;
                    ffi.operation = operation;
                }
                if let Some(blocker) = blocker {
                    ffi.has_blocker = 1;
                    ffi.blocker = blocker;
                }
            }
            Decision::GarbageCollected(operation) => {
                ffi.kind = DECISION_GARBAGE_COLLECTED;
                ffi.has_operation = 1;
                ffi.operation = operation;
            }
            Decision::Rejected(rejection) => {
                ffi.kind = DECISION_REJECTED;
                ffi.rejection = rejection as u32;
            }
        }
        ffi
    }
}

#[repr(C)]
pub struct FfiAuthority {
    reducer: Mutex<AuthorityReducer>,
}

fn lock_reducer(authority: &FfiAuthority) -> Result<MutexGuard<'_, AuthorityReducer>, u32> {
    authority.reducer.lock().map_err(|_| RUNTIME_POISONED)
}

fn with_authority(
    authority: *mut FfiAuthority,
    output: *mut FfiDecision,
    operation: impl FnOnce(&mut AuthorityReducer) -> Decision,
) -> u32 {
    if authority.is_null() || output.is_null() {
        return RUNTIME_NULL_POINTER;
    }
    // SAFETY: Null pointers were rejected. The C caller owns the authority until destroy and
    // supplies writable storage for the output. The mutex serializes reducer mutations.
    let authority = unsafe { &*authority };
    let mut reducer = match lock_reducer(authority) {
        Ok(reducer) => reducer,
        Err(status) => return status,
    };
    let decision = operation(&mut reducer);
    let result = FfiDecision::from_decision(decision, reducer.snapshot());
    drop(reducer);
    // SAFETY: The caller provided a nonnull writable output pointer for this call.
    unsafe { output.write(result) };
    RUNTIME_OK
}

#[no_mangle]
pub const extern "C" fn osata_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn osata_authority_create(initial_authority_epoch: u64) -> *mut FfiAuthority {
    AuthorityReducer::new(initial_authority_epoch).map_or(std::ptr::null_mut(), |reducer| {
        Box::into_raw(Box::new(FfiAuthority {
            reducer: Mutex::new(reducer),
        }))
    })
}

/// # Safety
///
/// `authority` must be null or a pointer returned by `osata_authority_create` that has not already
/// been destroyed. No other call may use the pointer concurrently with destruction.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_destroy(authority: *mut FfiAuthority) {
    if !authority.is_null() {
        // SAFETY: Required by the function contract; reconstructing the Box drops it exactly once.
        unsafe { drop(Box::from_raw(authority)) };
    }
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_snapshot(
    authority: *mut FfiAuthority,
    output: *mut Snapshot,
) -> u32 {
    if authority.is_null() || output.is_null() {
        return RUNTIME_NULL_POINTER;
    }
    // SAFETY: Null was rejected and ownership is retained by the C caller.
    let authority = unsafe { &*authority };
    let reducer = match lock_reducer(authority) {
        Ok(reducer) => reducer,
        Err(status) => return status,
    };
    let snapshot = reducer.snapshot();
    drop(reducer);
    // SAFETY: The caller supplied writable storage for the output snapshot.
    unsafe { output.write(snapshot) };
    RUNTIME_OK
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_bind_device(
    authority: *mut FfiAuthority,
    expected_reducer_revision: u64,
    device_instance_generation: u64,
    observation_registration_generation: u64,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.bind_device(
            expected_reducer_revision,
            device_instance_generation,
            observation_registration_generation,
        )
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_retire_device(
    authority: *mut FfiAuthority,
    expected_reducer_revision: u64,
    receipt: NativeDeviceTeardownReceipt,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.retire_device(expected_reducer_revision, receipt)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_arm(
    authority: *mut FfiAuthority,
    expected_reducer_revision: u64,
    observation_head: u64,
    operation_id: OperationId,
    target: Target,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.arm(
            expected_reducer_revision,
            observation_head,
            operation_id,
            target,
        )
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_apply_boundary(
    authority: *mut FfiAuthority,
    expected_reducer_revision: u64,
    observation_head: u64,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.apply_boundary(expected_reducer_revision, observation_head)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_abort_unpublished(
    authority: *mut FfiAuthority,
    expected_reducer_revision: u64,
    operation_receipt: OperationReceipt,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.abort_unpublished(expected_reducer_revision, operation_receipt)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_arm_successor(
    authority: *mut FfiAuthority,
    boundary_receipt: BoundaryReceipt,
    observation_head: u64,
    operation_id: OperationId,
    target: Target,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.arm_successor(boundary_receipt, observation_head, operation_id, target)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_acknowledge_native(
    authority: *mut FfiAuthority,
    receipt: NativeRecoveryReceipt,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.acknowledge_native(receipt)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_observe(
    authority: *mut FfiAuthority,
    receipt: NativeObservationReceipt,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| reducer.observe(receipt))
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_resolve_proof(
    authority: *mut FfiAuthority,
    proof_receipt: ProofReceipt,
    proof_outcome: u32,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        let Ok(outcome) = ProofOutcome::try_from(proof_outcome) else {
            return Decision::Rejected(Rejection::InvalidInput);
        };
        reducer.resolve_proof(proof_receipt, outcome)
    })
}

/// # Safety
///
/// `authority` must be a live pointer returned by create, and `output` must be writable.
#[no_mangle]
pub unsafe extern "C" fn osata_authority_collect_retired(
    authority: *mut FfiAuthority,
    receipt: NativeDrainReceipt,
    output: *mut FfiDecision,
) -> u32 {
    with_authority(authority, output, |reducer| {
        reducer.collect_retired(receipt)
    })
}
