use opensteamer_audio_transaction_authority::{
    AuthorityReducer, BoundaryReceipt, Decision, IgnoreReason, NativeDeviceTeardownReceipt,
    NativeDrainReceipt, NativeObservationReceipt, NativeOutcome, NativeRecoveryReceipt,
    OperationId, OperationReceipt, ProofOutcome, ProofReceipt, Rejection, Target, MAX_TOMBSTONES,
};

const TEST_DEVICE_GENERATION: u64 = 61;
const TEST_REGISTRATION_GENERATION: u64 = 51;

const fn operation_id(value: u64) -> OperationId {
    OperationId {
        high: 0xA11D_0000_0000_0000,
        low: value,
    }
}

const fn output_target() -> Target {
    Target {
        category: Target::CATEGORY_PLAYBACK,
        mode: Target::MODE_DEFAULT,
        options: 0,
        route_sharing_policy: 0,
        input_required: 0,
        reserved: 0,
    }
}

const fn input_target() -> Target {
    Target {
        category: Target::CATEGORY_PLAY_AND_RECORD,
        mode: Target::MODE_DEFAULT,
        options: 12,
        route_sharing_policy: 0,
        input_required: 1,
        reserved: 0,
    }
}

fn arm(
    reducer: &mut AuthorityReducer,
    id: u64,
    target: Target,
    observation_head: u64,
) -> (OperationReceipt, ProofReceipt) {
    if reducer.snapshot().device_instance_generation == 0 {
        let revision = reducer.snapshot().reducer_revision;
        assert_eq!(
            reducer.bind_device(
                revision,
                TEST_DEVICE_GENERATION,
                TEST_REGISTRATION_GENERATION,
            ),
            Decision::DeviceBound
        );
    }
    let revision = reducer.snapshot().reducer_revision;
    match reducer.arm(revision, observation_head, operation_id(id), target) {
        Decision::Armed {
            operation, proof, ..
        } => (operation, proof),
        other => panic!("arm failed: {other:?}"),
    }
}

fn boundary(reducer: &mut AuthorityReducer, observation_head: u64) -> BoundaryReceipt {
    let revision = reducer.snapshot().reducer_revision;
    match reducer.apply_boundary(revision, observation_head) {
        Decision::BoundaryApplied(receipt) => receipt,
        other => panic!("boundary failed: {other:?}"),
    }
}

fn arm_successor(
    reducer: &mut AuthorityReducer,
    boundary: BoundaryReceipt,
    id: u64,
    target: Target,
    observation_head: u64,
) -> (OperationReceipt, ProofReceipt) {
    match reducer.arm_successor(boundary, observation_head, operation_id(id), target) {
        Decision::Armed {
            operation, proof, ..
        } => (operation, proof),
        other => panic!("successor arm failed: {other:?}"),
    }
}

fn native_receipt(
    operation: OperationReceipt,
    outcome: NativeOutcome,
    exact_policy: bool,
) -> NativeRecoveryReceipt {
    NativeRecoveryReceipt {
        operation,
        authorization_generation: 71,
        terminal_generation: 71,
        outcome: outcome as u32,
        policy_matches_requested_target: u32::from(exact_policy),
    }
}

const fn observation_receipt(
    operation: OperationReceipt,
    target: Target,
    sequence: u64,
    disposition: u32,
) -> NativeObservationReceipt {
    NativeObservationReceipt {
        app_operation: operation,
        app_operation_tag_generation: 3,
        device_instance_generation: TEST_DEVICE_GENERATION,
        native_transaction_identifier: 5,
        notification_sequence: sequence,
        transaction_observer_sequence_baseline: sequence - 1,
        transaction_configuration_generation: 7,
        observed_configuration_generation: 7,
        transaction_system_audio_generation: 11,
        observed_system_audio_generation: 11,
        observed_at_nanoseconds: 100,
        transaction_deadline_nanoseconds: 200,
        disposition,
        transaction_state_at_ingress: NativeObservationReceipt::TRANSACTION_STATE_CONSUMED,
        has_app_operation: 1,
        policy_tuple_is_exact: 1,
        transaction_evidence_is_exact: 1,
        input_required: target.input_required,
        reserved: 0,
        alignment_reserved: 0,
        expected_target: target,
        observed_target: target,
    }
}

const fn staged_drain_receipt(
    operation: OperationReceipt,
    notification_sequence_watermark: u64,
    drain_generation: u64,
) -> NativeDrainReceipt {
    NativeDrainReceipt {
        operation,
        app_operation_tag_generation: operation.operation_revision + 100,
        native_transaction_identifier: 0,
        transaction_configuration_generation: 0,
        system_audio_generation: 41,
        notification_sequence_watermark,
        observation_registration_generation: TEST_REGISTRATION_GENERATION,
        drain_generation,
        device_instance_generation: TEST_DEVICE_GENERATION,
        binding_state: NativeDrainReceipt::BINDING_STATE_STAGED,
        ingress_in_flight_count: 0,
        reserved0: 0,
        reserved1: 0,
    }
}

const fn bound_drain_receipt(
    operation: OperationReceipt,
    notification_sequence_watermark: u64,
    drain_generation: u64,
) -> NativeDrainReceipt {
    NativeDrainReceipt {
        operation,
        app_operation_tag_generation: 3,
        native_transaction_identifier: 5,
        transaction_configuration_generation: 7,
        system_audio_generation: 11,
        notification_sequence_watermark,
        observation_registration_generation: TEST_REGISTRATION_GENERATION,
        drain_generation,
        device_instance_generation: TEST_DEVICE_GENERATION,
        binding_state: NativeDrainReceipt::BINDING_STATE_BOUND,
        ingress_in_flight_count: 0,
        reserved0: 0,
        reserved1: 0,
    }
}

const fn device_teardown_receipt(
    device_instance_generation: u64,
    observation_registration_generation: u64,
    notification_sequence_watermark: u64,
    teardown_generation: u64,
) -> NativeDeviceTeardownReceipt {
    NativeDeviceTeardownReceipt {
        device_instance_generation,
        observation_registration_generation,
        notification_sequence_watermark,
        teardown_generation,
        ingress_in_flight_count: 0,
        reserved0: 0,
        reserved1: 0,
        reserved2: 0,
    }
}

#[test]
fn exact_native_ack_and_proof_complete_without_category_notification_in_either_order() {
    for proof_first in [false, true] {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let (operation, proof) = arm(&mut reducer, 1, output_target(), 0);

        let first = if proof_first {
            reducer.resolve_proof(proof, ProofOutcome::Accepted)
        } else {
            reducer.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true))
        };
        assert!(matches!(
            first,
            Decision::WaitingForNativeAcknowledgement(_) | Decision::NativeAcknowledged(_)
        ));

        let second = if proof_first {
            reducer.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true))
        } else {
            reducer.resolve_proof(proof, ProofOutcome::Accepted)
        };
        assert_eq!(second, Decision::Completed(operation));
    }
}

#[test]
fn no_single_observation_ack_or_proof_can_complete_an_operation() {
    let target = output_target();

    let mut observed = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut observed, 1, target, 0);
    assert!(matches!(
        observed.observe(observation_receipt(
            operation,
            target,
            1,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        )),
        Decision::ObservationAccepted { .. }
    ));

    let mut acknowledged = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut acknowledged, 2, target, 0);
    assert_eq!(
        acknowledged.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true,)),
        Decision::NativeAcknowledged(operation)
    );

    let mut proved = AuthorityReducer::new(1).unwrap();
    let (operation, proof) = arm(&mut proved, 3, target, 0);
    assert_eq!(
        proved.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::WaitingForNativeAcknowledgement(operation)
    );
}

#[test]
fn retired_boundary_observation_is_ignored_without_mutating_successor() {
    let target = output_target();
    let mut reducer = AuthorityReducer::new(4).unwrap();
    let (operation_c, _) = arm(&mut reducer, 1, target, 0);
    let boundary = boundary(&mut reducer, 0);
    assert_eq!(boundary.blocker(), Some(operation_c));
    let (operation_b, proof_b) = arm_successor(&mut reducer, boundary, 2, target, 0);
    let before = reducer.snapshot();

    let decision = reducer.observe(observation_receipt(
        operation_c,
        target,
        2,
        NativeObservationReceipt::DISPOSITION_EXPECTED_RETIRED_APP_OPERATION,
    ));
    assert_eq!(
        decision,
        Decision::Ignored {
            reason: IgnoreReason::RetiredOperation,
            operation: Some(operation_b),
            blocker: Some(operation_c),
        }
    );
    assert_eq!(reducer.snapshot(), before);

    assert_eq!(
        reducer.acknowledge_native(native_receipt(operation_b, NativeOutcome::Accepted, true,)),
        Decision::NativeAcknowledged(operation_b)
    );
    assert_eq!(
        reducer.resolve_proof(proof_b, ProofOutcome::Accepted),
        Decision::Completed(operation_b)
    );
}

#[test]
fn intervening_operation_makes_boundary_receipt_stale_without_revoking_intervening_owner() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let _ = arm(&mut reducer, 1, output_target(), 0);
    let recovery_boundary = boundary(&mut reducer, 0);
    let (operation_d, _) = arm(&mut reducer, 2, input_target(), 0);
    let before = reducer.snapshot();

    assert_eq!(
        reducer.arm_successor(recovery_boundary, 0, operation_id(3), output_target(),),
        Decision::Rejected(Rejection::StaleRevision)
    );
    assert_eq!(reducer.snapshot(), before);
    assert_eq!(before.current_operation, operation_d);
}

#[test]
fn successor_exposes_predecessor_only_when_the_boundary_target_matches() {
    let mut matching = AuthorityReducer::new(1).unwrap();
    let (matching_predecessor, _) = arm(&mut matching, 1, output_target(), 0);
    let matching_boundary = boundary(&mut matching, 0);
    assert!(matches!(
        matching.arm_successor(matching_boundary, 0, operation_id(2), output_target()),
        Decision::Armed {
            predecessor: Some(predecessor),
            ..
        } if predecessor == matching_predecessor
    ));

    let mut mismatching = AuthorityReducer::new(1).unwrap();
    let _ = arm(&mut mismatching, 3, input_target(), 0);
    let mismatching_boundary = boundary(&mut mismatching, 0);
    assert!(matches!(
        mismatching.arm_successor(mismatching_boundary, 0, operation_id(4), output_target()),
        Decision::Armed {
            predecessor: None,
            ..
        }
    ));
}

#[test]
fn exact_duplicates_and_late_current_receipts_are_idempotent() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (operation, proof) = arm(&mut reducer, 1, target, 0);
    let observation = observation_receipt(
        operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    assert!(matches!(
        reducer.observe(observation),
        Decision::ObservationAccepted { .. }
    ));
    let after_observation = reducer.snapshot();
    assert!(matches!(
        reducer.observe(observation),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), after_observation);

    let native = native_receipt(operation, NativeOutcome::Accepted, true);
    assert_eq!(
        reducer.acknowledge_native(native),
        Decision::NativeAcknowledged(operation)
    );
    let after_native = reducer.snapshot();
    assert!(matches!(
        reducer.acknowledge_native(native),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), after_native);

    assert_eq!(
        reducer.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::Completed(operation)
    );
    let completed = reducer.snapshot();
    assert!(matches!(
        reducer.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            ..
        }
    ));
    let mut late_observation = observation;
    late_observation.notification_sequence = 2;
    late_observation.observed_at_nanoseconds += 1;
    assert!(matches!(
        reducer.observe(late_observation),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), completed);
}

#[test]
fn post_completion_receipt_mutations_fail_closed_while_exact_duplicates_are_idempotent() {
    type NativeMutation = fn(&mut NativeRecoveryReceipt);
    let native_mutations: &[NativeMutation] = &[
        |receipt| receipt.authorization_generation += 1,
        |receipt| receipt.terminal_generation += 1,
        |receipt| receipt.outcome = NativeOutcome::Revoked as u32,
        |receipt| receipt.policy_matches_requested_target = 0,
    ];

    for (index, mutation) in native_mutations.iter().enumerate() {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let (operation, proof) = arm(&mut reducer, index as u64 + 1, output_target(), 0);
        let receipt = native_receipt(operation, NativeOutcome::Accepted, true);
        assert_eq!(
            reducer.acknowledge_native(receipt),
            Decision::NativeAcknowledged(operation)
        );
        assert_eq!(
            reducer.resolve_proof(proof, ProofOutcome::Accepted),
            Decision::Completed(operation)
        );
        let mut mutated = receipt;
        mutation(&mut mutated);
        assert_eq!(
            reducer.acknowledge_native(mutated),
            Decision::FailedClosed(Some(operation)),
            "native mutation {index}"
        );
    }

    let mut proof_mutation = AuthorityReducer::new(1).unwrap();
    let (operation, proof) = arm(&mut proof_mutation, 20, output_target(), 0);
    assert_eq!(
        proof_mutation
            .acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true,)),
        Decision::NativeAcknowledged(operation)
    );
    assert_eq!(
        proof_mutation.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::Completed(operation)
    );
    assert_eq!(
        proof_mutation.resolve_proof(proof, ProofOutcome::Rejected),
        Decision::FailedClosed(Some(operation))
    );

    let mut observation_mutation = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (operation, proof) = arm(&mut observation_mutation, 21, target, 0);
    let observation = observation_receipt(
        operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    assert!(matches!(
        observation_mutation.observe(observation),
        Decision::ObservationAccepted { .. }
    ));
    assert_eq!(
        observation_mutation.acknowledge_native(native_receipt(
            operation,
            NativeOutcome::Accepted,
            true,
        )),
        Decision::NativeAcknowledged(operation)
    );
    assert_eq!(
        observation_mutation.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::Completed(operation)
    );
    let mut conflicting_observation = observation;
    conflicting_observation.notification_sequence += 1;
    conflicting_observation.observed_at_nanoseconds += 1;
    conflicting_observation.native_transaction_identifier += 1;
    assert_eq!(
        observation_mutation.observe(conflicting_observation),
        Decision::FailedClosed(Some(operation))
    );
}

#[test]
fn repeated_observation_requires_the_same_native_transaction_and_tag() {
    let target = output_target();

    let mutations: [fn(&mut NativeObservationReceipt); 2] = [
        |receipt: &mut NativeObservationReceipt| receipt.native_transaction_identifier += 1,
        |receipt: &mut NativeObservationReceipt| receipt.app_operation_tag_generation += 1,
    ];
    for mutate_identity in mutations {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let (operation, _) = arm(&mut reducer, 1, target, 0);
        let first = observation_receipt(
            operation,
            target,
            1,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        );
        assert!(matches!(
            reducer.observe(first),
            Decision::ObservationAccepted { .. }
        ));

        let mut conflicting = first;
        conflicting.notification_sequence = 2;
        conflicting.observed_at_nanoseconds += 1;
        mutate_identity(&mut conflicting);
        assert_eq!(
            reducer.observe(conflicting),
            Decision::FailedClosed(Some(operation))
        );
    }
}

#[test]
fn later_notification_for_the_same_native_transaction_is_idempotent() {
    let target = output_target();
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut reducer, 1, target, 0);
    let first = observation_receipt(
        operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    assert!(matches!(
        reducer.observe(first),
        Decision::ObservationAccepted { .. }
    ));
    let before = reducer.snapshot();

    let mut later = first;
    later.notification_sequence = 2;
    later.observed_at_nanoseconds += 1;
    later.transaction_state_at_ingress = NativeObservationReceipt::TRANSACTION_STATE_CONSUMED;
    assert_eq!(
        reducer.observe(later),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            operation: Some(operation),
            blocker: None,
        }
    );
    assert_eq!(reducer.snapshot(), before);
}

#[test]
fn malformed_or_tuple_only_current_observation_fails_closed() {
    type Mutation = fn(&mut NativeObservationReceipt);
    let mutations: &[Mutation] = &[
        |receipt| receipt.has_app_operation = 0,
        |receipt| receipt.has_app_operation = 2,
        |receipt| receipt.app_operation_tag_generation = 0,
        |receipt| receipt.device_instance_generation = 0,
        |receipt| receipt.native_transaction_identifier = 0,
        |receipt| receipt.notification_sequence = receipt.transaction_observer_sequence_baseline,
        |receipt| receipt.transaction_configuration_generation = 0,
        |receipt| receipt.observed_configuration_generation += 1,
        |receipt| receipt.transaction_system_audio_generation = 0,
        |receipt| receipt.observed_system_audio_generation += 1,
        |receipt| receipt.observed_at_nanoseconds = 0,
        |receipt| receipt.transaction_deadline_nanoseconds = 0,
        |receipt| receipt.observed_at_nanoseconds = 201,
        |receipt| receipt.policy_tuple_is_exact = 0,
        |receipt| receipt.policy_tuple_is_exact = 2,
        |receipt| receipt.transaction_evidence_is_exact = 0,
        |receipt| receipt.transaction_evidence_is_exact = 2,
        |receipt| receipt.input_required ^= 1,
        |receipt| receipt.input_required = 2,
        |receipt| receipt.reserved = 1,
        |receipt| receipt.alignment_reserved = 1,
        |receipt| receipt.expected_target.reserved = 1,
        |receipt| receipt.observed_target.reserved = 1,
        |receipt| receipt.observed_target.options += 1,
        |receipt| receipt.disposition = u32::MAX,
        |receipt| receipt.transaction_state_at_ingress = u32::MAX,
        |receipt| {
            receipt.disposition =
                NativeObservationReceipt::DISPOSITION_EXPECTED_UNCORRELATED_TRANSACTION;
        },
        |receipt| {
            receipt.disposition = NativeObservationReceipt::DISPOSITION_TRACKED_POLICY_MISMATCH;
        },
        |receipt| {
            receipt.transaction_state_at_ingress =
                NativeObservationReceipt::TRANSACTION_STATE_REJECTED;
        },
    ];

    for (index, mutation) in mutations.iter().enumerate() {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let target = output_target();
        let (operation, _) = arm(&mut reducer, index as u64 + 1, target, 0);
        let mut receipt = observation_receipt(
            operation,
            target,
            1,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        );
        mutation(&mut receipt);
        assert_eq!(
            reducer.observe(receipt),
            Decision::FailedClosed(Some(operation)),
            "mutation {index} did not fail closed"
        );
    }
}

#[test]
fn native_generation_and_exact_policy_are_enforced_in_rust() {
    type Mutation = fn(&mut NativeRecoveryReceipt);
    let mutations: &[Mutation] = &[
        |receipt| receipt.authorization_generation = 0,
        |receipt| receipt.terminal_generation = 0,
        |receipt| receipt.terminal_generation += 1,
        |receipt| receipt.outcome = 0,
        |receipt| receipt.outcome = u32::MAX,
        |receipt| receipt.policy_matches_requested_target = 2,
    ];
    for (index, mutation) in mutations.iter().enumerate() {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let (operation, _) = arm(&mut reducer, index as u64 + 1, output_target(), 0);
        let before = reducer.snapshot();
        let mut invalid = native_receipt(operation, NativeOutcome::Accepted, true);
        mutation(&mut invalid);
        assert_eq!(
            reducer.acknowledge_native(invalid),
            Decision::Rejected(Rejection::InvalidInput),
            "native canonical mutation {index}"
        );
        assert_eq!(reducer.snapshot(), before);
    }

    let mut reducer = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut reducer, 100, output_target(), 0);
    assert_eq!(
        reducer.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, false,)),
        Decision::FailedClosed(Some(operation))
    );
}

#[test]
fn any_negative_terminal_evidence_prevents_completion_in_both_orders() {
    for native in [
        NativeOutcome::Accepted,
        NativeOutcome::Rejected,
        NativeOutcome::Revoked,
    ] {
        for proof in [ProofOutcome::Accepted, ProofOutcome::Rejected] {
            for proof_first in [false, true] {
                let mut reducer = AuthorityReducer::new(1).unwrap();
                let (operation, proof_receipt) = arm(&mut reducer, 1, output_target(), 0);
                let first = if proof_first {
                    reducer.resolve_proof(proof_receipt, proof)
                } else {
                    reducer.acknowledge_native(native_receipt(operation, native, true))
                };
                let second = if proof_first {
                    reducer.acknowledge_native(native_receipt(operation, native, true))
                } else {
                    reducer.resolve_proof(proof_receipt, proof)
                };
                let should_complete =
                    native == NativeOutcome::Accepted && proof == ProofOutcome::Accepted;
                assert_eq!(
                    matches!(first, Decision::Completed(_))
                        || matches!(second, Decision::Completed(_)),
                    should_complete,
                    "native={native:?} proof={proof:?} proof_first={proof_first}"
                );
            }
        }
    }
}

#[test]
fn exhaustive_positive_event_sequences_require_both_native_ack_and_proof() {
    const EVENT_COUNT: u64 = 3;
    const SEQUENCE_LENGTH: u32 = 5;
    let sequence_count = EVENT_COUNT.pow(SEQUENCE_LENGTH);

    for encoded in 0..sequence_count {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let target = output_target();
        let (operation, proof) = arm(&mut reducer, encoded + 1, target, 0);
        let observation = observation_receipt(
            operation,
            target,
            1,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        );
        let mut remaining = encoded;
        let mut contained_ack = false;
        let mut contained_proof = false;
        let mut completed = false;

        for _ in 0..SEQUENCE_LENGTH {
            let event = remaining % EVENT_COUNT;
            remaining /= EVENT_COUNT;
            let decision = match event {
                0 => {
                    contained_ack = true;
                    reducer.acknowledge_native(native_receipt(
                        operation,
                        NativeOutcome::Accepted,
                        true,
                    ))
                }
                1 => {
                    contained_proof = true;
                    reducer.resolve_proof(proof, ProofOutcome::Accepted)
                }
                2 => reducer.observe(observation),
                _ => unreachable!(),
            };
            if event == 2 {
                assert!(
                    !matches!(decision, Decision::Completed(_)),
                    "observation authorized sequence {encoded}"
                );
            }
            completed |= matches!(decision, Decision::Completed(_));
        }

        assert_eq!(
            completed,
            contained_ack && contained_proof,
            "completion mismatch for encoded sequence {encoded}"
        );
    }
    assert_eq!(sequence_count, 243);
}

#[test]
fn stale_ack_and_proof_cannot_mutate_replacement_operation() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let (old_operation, old_proof) = arm(&mut reducer, 1, output_target(), 0);
    let _ = boundary(&mut reducer, 0);
    let (replacement, _) = arm(&mut reducer, 2, input_target(), 0);
    let before = reducer.snapshot();

    assert!(matches!(
        reducer.acknowledge_native(native_receipt(old_operation, NativeOutcome::Accepted, true,)),
        Decision::Ignored {
            reason: IgnoreReason::RetiredOperation,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), before);
    assert!(matches!(
        reducer.resolve_proof(old_proof, ProofOutcome::Accepted),
        Decision::Ignored {
            reason: IgnoreReason::RetiredOperation,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), before);
    assert_eq!(before.current_operation, replacement);
}

#[test]
fn exact_native_drain_collects_only_its_tombstone_and_is_idempotent() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let (retired_a, _) = arm(&mut reducer, 1, output_target(), 0);
    let _ = boundary(&mut reducer, 0);
    let (retired_b, _) = arm(&mut reducer, 2, input_target(), 0);
    let _ = boundary(&mut reducer, 0);
    let receipt = staged_drain_receipt(retired_a, 0, 1);

    assert_eq!(
        reducer.collect_retired(receipt),
        Decision::GarbageCollected(retired_a)
    );
    assert_eq!(reducer.snapshot().tombstone_count, 1);
    let after_collection = reducer.snapshot();
    assert_eq!(
        reducer.collect_retired(receipt),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            operation: Some(retired_a),
            blocker: None,
        }
    );
    assert_eq!(reducer.snapshot(), after_collection);

    let before = reducer.snapshot();
    let mut mutated_duplicate = receipt;
    mutated_duplicate.app_operation_tag_generation += 1;
    assert_eq!(
        reducer.collect_retired(mutated_duplicate),
        Decision::Rejected(Rejection::Duplicate)
    );
    assert_eq!(reducer.snapshot(), before);

    assert_eq!(
        reducer.collect_retired(staged_drain_receipt(retired_b, 0, 2)),
        Decision::GarbageCollected(retired_b)
    );
    assert_eq!(reducer.snapshot().tombstone_count, 0);
}

#[test]
fn stale_or_under_cutoff_drain_cannot_collect_a_tombstone() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (retired, _) = arm(&mut reducer, 1, target, 0);
    assert!(matches!(
        reducer.observe(observation_receipt(
            retired,
            target,
            5,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        )),
        Decision::ObservationAccepted { .. }
    ));
    let _ = boundary(&mut reducer, 5);
    let before = reducer.snapshot();

    assert_eq!(
        reducer.collect_retired(bound_drain_receipt(retired, 4, 1)),
        Decision::Rejected(Rejection::InvalidInput)
    );
    assert_eq!(reducer.snapshot(), before);

    let mut stale = bound_drain_receipt(retired, 5, 1);
    stale.operation.operation_id = operation_id(999);
    assert_eq!(
        reducer.collect_retired(stale),
        Decision::Rejected(Rejection::StaleOperation)
    );
    assert_eq!(reducer.snapshot(), before);

    assert_eq!(
        reducer.collect_retired(bound_drain_receipt(retired, 5, 1)),
        Decision::GarbageCollected(retired)
    );
}

#[test]
fn observed_tombstone_requires_exact_bound_drain_provenance() {
    type Mutation = fn(&mut NativeDrainReceipt);
    let mutations: &[Mutation] = &[
        |receipt| receipt.app_operation_tag_generation = 0,
        |receipt| receipt.app_operation_tag_generation += 1,
        |receipt| receipt.native_transaction_identifier += 1,
        |receipt| receipt.transaction_configuration_generation += 1,
        |receipt| receipt.system_audio_generation = 0,
        |receipt| receipt.system_audio_generation += 1,
        |receipt| receipt.notification_sequence_watermark = 0,
        |receipt| receipt.observation_registration_generation = 0,
        |receipt| receipt.drain_generation = 0,
        |receipt| receipt.device_instance_generation = 0,
        |receipt| receipt.binding_state = 0,
        |receipt| receipt.binding_state = u32::MAX,
        |receipt| receipt.binding_state = NativeDrainReceipt::BINDING_STATE_STAGED,
        |receipt| receipt.ingress_in_flight_count = 1,
        |receipt| receipt.reserved0 = 1,
        |receipt| receipt.reserved1 = 1,
    ];

    for (index, mutation) in mutations.iter().enumerate() {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let target = output_target();
        let (operation, _) = arm(&mut reducer, index as u64 + 1, target, 0);
        assert!(matches!(
            reducer.observe(observation_receipt(
                operation,
                target,
                1,
                NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
            )),
            Decision::ObservationAccepted { .. }
        ));
        let _ = boundary(&mut reducer, 1);
        let before = reducer.snapshot();
        let mut receipt = bound_drain_receipt(operation, 1, index as u64 + 1);
        mutation(&mut receipt);
        assert!(matches!(
            reducer.collect_retired(receipt),
            Decision::Rejected(Rejection::InvalidInput)
        ));
        assert_eq!(reducer.snapshot(), before, "drain mutation {index}");
    }
}

#[test]
fn forged_boundary_lineage_is_rejected_without_state_change() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let _ = arm(&mut reducer, 1, output_target(), 0);
    let mut receipt = boundary(&mut reducer, 0);
    receipt.blocker.operation_revision += 1;
    let before = reducer.snapshot();
    assert_eq!(
        reducer.arm_successor(receipt, 0, operation_id(2), output_target()),
        Decision::Rejected(Rejection::StaleRevision)
    );
    assert_eq!(reducer.snapshot(), before);
}

#[test]
fn tombstone_capacity_exhaustion_fails_without_retiring_current() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    for index in 0..MAX_TOMBSTONES {
        let _ = arm(&mut reducer, index as u64 + 1, output_target(), 0);
        let _ = boundary(&mut reducer, 0);
    }
    let (current, _) = arm(
        &mut reducer,
        u64::try_from(MAX_TOMBSTONES).unwrap() + 1,
        output_target(),
        0,
    );
    let before = reducer.snapshot();
    assert_eq!(
        reducer.apply_boundary(before.reducer_revision, 0),
        Decision::Rejected(Rejection::CapacityExceeded)
    );
    assert_eq!(reducer.snapshot(), before);
    assert_eq!(before.current_operation, current);
}

#[test]
fn unbound_reducer_rejects_arm_until_exact_device_registration_is_bound() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let initial = reducer.snapshot();
    assert_eq!(
        reducer.arm(
            initial.reducer_revision,
            0,
            operation_id(1),
            output_target(),
        ),
        Decision::Rejected(Rejection::StaleAuthority)
    );
    assert_eq!(reducer.snapshot(), initial);
    assert_eq!(
        reducer.apply_boundary(initial.reducer_revision, 0),
        Decision::Rejected(Rejection::StaleAuthority)
    );
    assert_eq!(reducer.snapshot(), initial);
    assert_eq!(
        reducer.bind_device(
            initial.reducer_revision,
            TEST_DEVICE_GENERATION,
            TEST_REGISTRATION_GENERATION,
        ),
        Decision::DeviceBound
    );
    assert_eq!(
        reducer.bind_device(
            reducer.snapshot().reducer_revision,
            TEST_DEVICE_GENERATION,
            TEST_REGISTRATION_GENERATION,
        ),
        Decision::Ignored {
            reason: IgnoreReason::ExactDuplicate,
            operation: None,
            blocker: None,
        }
    );
}

#[test]
fn arm_and_boundary_reject_fabricated_future_observation_heads() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    assert_eq!(
        reducer.bind_device(
            reducer.snapshot().reducer_revision,
            TEST_DEVICE_GENERATION,
            TEST_REGISTRATION_GENERATION,
        ),
        Decision::DeviceBound
    );
    let bound = reducer.snapshot();
    assert_eq!(
        reducer.arm(bound.reducer_revision, 1, operation_id(1), output_target(),),
        Decision::Rejected(Rejection::InvalidInput)
    );
    assert_eq!(reducer.snapshot(), bound);

    let (operation, _) = arm(&mut reducer, 1, output_target(), 0);
    let armed = reducer.snapshot();
    assert_eq!(
        reducer.apply_boundary(armed.reducer_revision, 1),
        Decision::Rejected(Rejection::InvalidInput)
    );
    assert_eq!(reducer.snapshot(), armed);
    assert_eq!(armed.current_operation, operation);

    let exact_boundary = boundary(&mut reducer, 0);
    let after_boundary = reducer.snapshot();
    assert_eq!(
        reducer.arm_successor(exact_boundary, 1, operation_id(2), output_target()),
        Decision::Rejected(Rejection::InvalidInput)
    );
    assert_eq!(reducer.snapshot(), after_boundary);
}

#[test]
fn native_device_teardown_resets_sequence_and_old_receipts_cannot_mutate_new_device() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (old_operation, _) = arm(&mut reducer, 1, target, 0);
    let old_observation = observation_receipt(
        old_operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    assert!(matches!(
        reducer.observe(old_observation),
        Decision::ObservationAccepted { .. }
    ));
    let _ = boundary(&mut reducer, 1);
    let revision = reducer.snapshot().reducer_revision;
    let teardown =
        device_teardown_receipt(TEST_DEVICE_GENERATION, TEST_REGISTRATION_GENERATION, 1, 1);
    assert_eq!(
        reducer.retire_device(revision, teardown),
        Decision::DeviceRetired(None)
    );
    let retired = reducer.snapshot();
    assert_eq!(retired.device_instance_generation, 0);
    assert_eq!(retired.observation_registration_generation, 0);
    assert_eq!(retired.last_observation_sequence, 0);
    assert_eq!(retired.tombstone_count, 0);

    let new_device = TEST_DEVICE_GENERATION + 1;
    let new_registration = TEST_REGISTRATION_GENERATION + 1;
    assert_eq!(
        reducer.bind_device(retired.reducer_revision, new_device, new_registration),
        Decision::DeviceBound
    );
    let (new_operation, _) = arm(&mut reducer, 2, target, 0);
    let before_stale = reducer.snapshot();
    let mut late_old_observation = old_observation;
    late_old_observation.notification_sequence = 2;
    late_old_observation.observed_at_nanoseconds += 1;
    late_old_observation.disposition =
        NativeObservationReceipt::DISPOSITION_EXPECTED_RETIRED_APP_OPERATION;
    assert!(matches!(
        reducer.observe(late_old_observation),
        Decision::Ignored {
            reason: IgnoreReason::StaleDeviceGeneration,
            ..
        }
    ));
    assert_eq!(reducer.snapshot(), before_stale);

    let mut first_new_observation = observation_receipt(
        new_operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    first_new_observation.device_instance_generation = new_device;
    assert!(matches!(
        reducer.observe(first_new_observation),
        Decision::ObservationAccepted { .. }
    ));
    assert_eq!(reducer.snapshot().last_observation_sequence, 1);
}

#[test]
fn native_device_teardown_fail_retires_current_operation_and_permits_rebind() {
    let mut reducer = AuthorityReducer::new(9).unwrap();
    let (operation, proof) = arm(&mut reducer, 1, output_target(), 0);
    assert_eq!(
        reducer.resolve_proof(proof, ProofOutcome::Accepted),
        Decision::WaitingForNativeAcknowledgement(operation)
    );
    let before = reducer.snapshot();
    let teardown =
        device_teardown_receipt(TEST_DEVICE_GENERATION, TEST_REGISTRATION_GENERATION, 0, 1);

    assert_eq!(
        reducer.retire_device(before.reducer_revision, teardown),
        Decision::DeviceRetired(Some(operation))
    );
    let retired = reducer.snapshot();
    assert_eq!(retired.has_current_operation, 0);
    assert_eq!(retired.current_operation, OperationReceipt::default());
    assert_eq!(retired.device_instance_generation, 0);
    assert_eq!(retired.observation_registration_generation, 0);
    assert_eq!(retired.authority_epoch, before.authority_epoch + 1);
    assert_eq!(retired.reducer_revision, before.reducer_revision + 1);
    assert_eq!(
        retired.retired_operation_revision_watermark,
        operation.operation_revision
    );

    assert_eq!(
        reducer.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true)),
        Decision::Ignored {
            reason: IgnoreReason::WatermarkRetiredOperation,
            operation: Some(operation),
            blocker: None,
        }
    );
    assert_eq!(reducer.snapshot(), retired);

    assert_eq!(
        reducer.bind_device(
            retired.reducer_revision,
            TEST_DEVICE_GENERATION + 1,
            TEST_REGISTRATION_GENERATION + 1,
        ),
        Decision::DeviceBound
    );
    let (new_operation, _) = arm(&mut reducer, 2, output_target(), 0);
    assert_ne!(new_operation.authority_epoch, operation.authority_epoch);
}

#[test]
fn device_teardown_requires_exact_registration_barrier_and_cutoff() {
    type Mutation = fn(&mut NativeDeviceTeardownReceipt);
    let mutations: &[Mutation] = &[
        |receipt| receipt.device_instance_generation = 0,
        |receipt| receipt.observation_registration_generation = 0,
        |receipt| receipt.observation_registration_generation += 1,
        |receipt| receipt.notification_sequence_watermark = 4,
        |receipt| receipt.teardown_generation = 0,
        |receipt| receipt.ingress_in_flight_count = 1,
        |receipt| receipt.reserved0 = 1,
        |receipt| receipt.reserved1 = 1,
        |receipt| receipt.reserved2 = 1,
    ];

    for (index, mutation) in mutations.iter().enumerate() {
        let mut reducer = AuthorityReducer::new(1).unwrap();
        let target = output_target();
        let (operation, _) = arm(&mut reducer, index as u64 + 1, target, 0);
        assert!(matches!(
            reducer.observe(observation_receipt(
                operation,
                target,
                5,
                NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
            )),
            Decision::ObservationAccepted { .. }
        ));
        let _ = boundary(&mut reducer, 5);
        let before = reducer.snapshot();
        let mut receipt = device_teardown_receipt(
            TEST_DEVICE_GENERATION,
            TEST_REGISTRATION_GENERATION,
            5,
            index as u64 + 1,
        );
        mutation(&mut receipt);
        assert!(matches!(
            reducer.retire_device(before.reducer_revision, receipt),
            Decision::Rejected(_)
        ));
        assert_eq!(reducer.snapshot(), before, "teardown mutation {index}");
    }
}

#[test]
fn current_operation_requires_teardown_cutoff_covering_observed_head() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (operation, _) = arm(&mut reducer, 1, target, 0);
    assert!(matches!(
        reducer.observe(observation_receipt(
            operation,
            target,
            5,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        )),
        Decision::ObservationAccepted { .. }
    ));
    let before = reducer.snapshot();
    let under_cutoff =
        device_teardown_receipt(TEST_DEVICE_GENERATION, TEST_REGISTRATION_GENERATION, 4, 1);
    assert_eq!(
        reducer.retire_device(before.reducer_revision, under_cutoff),
        Decision::Rejected(Rejection::InvalidInput)
    );
    assert_eq!(reducer.snapshot(), before);

    let exact = device_teardown_receipt(TEST_DEVICE_GENERATION, TEST_REGISTRATION_GENERATION, 5, 1);
    assert_eq!(
        reducer.retire_device(before.reducer_revision, exact),
        Decision::DeviceRetired(Some(operation))
    );
}

#[test]
fn retirement_never_ignores_a_forged_id_from_an_earlier_revision_range() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (retired, _) = arm(&mut reducer, 1, target, 0);
    let _ = boundary(&mut reducer, 0);
    assert_eq!(
        reducer.collect_retired(staged_drain_receipt(retired, 0, 1)),
        Decision::GarbageCollected(retired)
    );

    let mut forged = retired;
    forged.operation_id = operation_id(999);
    let before_forged_ack = reducer.snapshot();
    assert_eq!(
        reducer.acknowledge_native(native_receipt(forged, NativeOutcome::Accepted, true)),
        Decision::Rejected(Rejection::StaleOperation)
    );
    assert_eq!(reducer.snapshot(), before_forged_ack);

    let (current, _) = arm(&mut reducer, 2, target, 0);
    let before_forged_observation = reducer.snapshot();
    let forged_observation = observation_receipt(
        forged,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_RETIRED_APP_OPERATION,
    );
    assert_eq!(
        reducer.observe(forged_observation),
        Decision::FailedClosed(Some(current))
    );
    assert_ne!(reducer.snapshot(), before_forged_observation);
}

#[test]
fn unknown_future_device_evidence_never_receives_stale_device_idempotence() {
    let future_device = TEST_DEVICE_GENERATION + 1;

    let mut observed = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (operation, _) = arm(&mut observed, 1, target, 0);
    let mut future_observation = observation_receipt(
        operation,
        target,
        1,
        NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
    );
    future_observation.device_instance_generation = future_device;
    assert_eq!(
        observed.observe(future_observation),
        Decision::FailedClosed(Some(operation))
    );

    let mut drained = AuthorityReducer::new(1).unwrap();
    let (retired, _) = arm(&mut drained, 2, target, 0);
    let _ = boundary(&mut drained, 0);
    let before_drain = drained.snapshot();
    let mut future_drain = staged_drain_receipt(retired, 0, 1);
    future_drain.device_instance_generation = future_device;
    assert_eq!(
        drained.collect_retired(future_drain),
        Decision::Rejected(Rejection::StaleAuthority)
    );
    assert_eq!(drained.snapshot(), before_drain);

    let future_teardown =
        device_teardown_receipt(future_device, TEST_REGISTRATION_GENERATION, 0, 1);
    assert_eq!(
        drained.retire_device(before_drain.reducer_revision, future_teardown),
        Decision::Rejected(Rejection::StaleAuthority)
    );
    assert_eq!(drained.snapshot(), before_drain);
}

#[test]
fn repeated_pre_effect_staging_failures_do_not_consume_tombstone_capacity() {
    let mut reducer = AuthorityReducer::new(1).unwrap();
    for index in 0..(MAX_TOMBSTONES * 3) {
        let (operation, _) = arm(&mut reducer, index as u64 + 1, output_target(), 0);
        let before = reducer.snapshot();
        assert_eq!(
            reducer.abort_unpublished(before.reducer_revision, operation),
            Decision::AbortedUnpublished(operation)
        );
        let after = reducer.snapshot();
        assert_eq!(after.has_current_operation, 0);
        assert_eq!(after.tombstone_count, 0);
        assert_eq!(after.authority_epoch, before.authority_epoch + 1);
    }
}

#[test]
fn abort_unpublished_is_exact_and_rejects_after_any_evidence() {
    let mut stale = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut stale, 1, output_target(), 0);
    let before = stale.snapshot();
    let mut wrong_operation = operation;
    wrong_operation.operation_id = operation_id(999);
    assert_eq!(
        stale.abort_unpublished(before.reducer_revision, wrong_operation),
        Decision::Rejected(Rejection::StaleOperation)
    );
    assert_eq!(stale.snapshot(), before);
    assert_eq!(
        stale.abort_unpublished(before.reducer_revision - 1, operation),
        Decision::Rejected(Rejection::StaleRevision)
    );
    assert_eq!(stale.snapshot(), before);

    let mut observed = AuthorityReducer::new(1).unwrap();
    let target = output_target();
    let (operation, _) = arm(&mut observed, 2, target, 0);
    assert!(matches!(
        observed.observe(observation_receipt(
            operation,
            target,
            1,
            NativeObservationReceipt::DISPOSITION_EXPECTED_CURRENT_APP_OPERATION,
        )),
        Decision::ObservationAccepted { .. }
    ));
    let before = observed.snapshot();
    assert_eq!(
        observed.abort_unpublished(before.reducer_revision, operation),
        Decision::Rejected(Rejection::StaleOperation)
    );
    assert_eq!(observed.snapshot(), before);

    let mut acknowledged = AuthorityReducer::new(1).unwrap();
    let (operation, _) = arm(&mut acknowledged, 3, target, 0);
    assert_eq!(
        acknowledged.acknowledge_native(native_receipt(operation, NativeOutcome::Accepted, true,)),
        Decision::NativeAcknowledged(operation)
    );
    let before = acknowledged.snapshot();
    assert_eq!(
        acknowledged.abort_unpublished(before.reducer_revision, operation),
        Decision::Rejected(Rejection::StaleOperation)
    );
    assert_eq!(acknowledged.snapshot(), before);
}
