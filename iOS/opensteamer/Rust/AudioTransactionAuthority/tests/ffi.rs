use std::mem::{align_of, size_of};

use opensteamer_audio_transaction_authority::{
    osata_abi_version, osata_authority_arm, osata_authority_bind_device, osata_authority_create,
    osata_authority_destroy, osata_authority_retire_device, osata_authority_snapshot,
    BoundaryReceipt, FfiDecision, NativeDeviceTeardownReceipt, NativeDrainReceipt,
    NativeObservationReceipt, NativeRecoveryReceipt, OperationId, OperationReceipt, ProofReceipt,
    Snapshot, Target, ABI_VERSION, DECISION_ARMED, DECISION_DEVICE_BOUND, DECISION_DEVICE_RETIRED,
    RUNTIME_NULL_POINTER, RUNTIME_OK,
};

#[test]
fn c_layout_sizes_match_the_published_header() {
    assert_eq!(size_of::<OperationId>(), 16);
    assert_eq!(size_of::<Target>(), 32);
    assert_eq!(size_of::<OperationReceipt>(), 32);
    assert_eq!(size_of::<BoundaryReceipt>(), 56);
    assert_eq!(size_of::<ProofReceipt>(), 40);
    assert_eq!(size_of::<NativeRecoveryReceipt>(), 56);
    assert_eq!(size_of::<NativeDrainReceipt>(), 112);
    assert_eq!(size_of::<NativeObservationReceipt>(), 216);
    assert_eq!(size_of::<NativeDeviceTeardownReceipt>(), 48);
    assert_eq!(size_of::<Snapshot>(), 104);
    assert_eq!(size_of::<FfiDecision>(), 208);
    assert_eq!(align_of::<OperationId>(), 8);
    assert_eq!(align_of::<Target>(), 8);
    assert_eq!(align_of::<OperationReceipt>(), 8);
    assert_eq!(align_of::<BoundaryReceipt>(), 8);
    assert_eq!(align_of::<ProofReceipt>(), 8);
    assert_eq!(align_of::<NativeRecoveryReceipt>(), 8);
    assert_eq!(align_of::<NativeDrainReceipt>(), 8);
    assert_eq!(align_of::<NativeObservationReceipt>(), 8);
    assert_eq!(align_of::<NativeDeviceTeardownReceipt>(), 8);
    assert_eq!(align_of::<Snapshot>(), 8);
    assert_eq!(align_of::<FfiDecision>(), 8);
}

#[test]
fn ffi_null_checks_and_arm_round_trip_are_deterministic() {
    assert_eq!(osata_abi_version(), ABI_VERSION);
    let authority = osata_authority_create(1);
    assert!(!authority.is_null());

    let mut snapshot = Snapshot::default();
    assert_eq!(
        // SAFETY: `authority` is live and `snapshot` is writable for this call.
        unsafe { osata_authority_snapshot(authority, &raw mut snapshot) },
        RUNTIME_OK
    );
    assert_eq!(snapshot.reducer_revision, 1);
    let mut decision = FfiDecision::default();
    assert_eq!(
        // SAFETY: `authority` is live and `decision` is writable for this call.
        unsafe { osata_authority_bind_device(authority, 1, 7, 11, &raw mut decision) },
        RUNTIME_OK
    );
    assert_eq!(decision.kind, DECISION_DEVICE_BOUND);
    assert_eq!(decision.reducer_revision, 2);

    // UUID bytes 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff. This deliberately
    // non-symmetric fixture catches high/low swaps and host-endian reinterpretation.
    let operation_id = OperationId {
        high: 0x0011_2233_4455_6677,
        low: 0x8899_AABB_CCDD_EEFF,
    };

    let target = Target {
        category: Target::CATEGORY_PLAYBACK,
        mode: Target::MODE_DEFAULT,
        options: 0,
        route_sharing_policy: 0,
        input_required: 0,
        reserved: 0,
    };
    assert_eq!(
        // SAFETY: `authority` is live and `decision` is writable for this call.
        unsafe {
            osata_authority_arm(
                authority,
                decision.reducer_revision,
                0,
                operation_id,
                target,
                &raw mut decision,
            )
        },
        RUNTIME_OK
    );
    assert_eq!(decision.kind, DECISION_ARMED);
    assert_eq!(decision.has_operation, 1);
    assert_eq!(decision.has_proof, 1);
    assert_eq!(decision.operation.operation_id, operation_id);
    assert_eq!(decision.proof.operation.operation_id, operation_id);

    let teardown = NativeDeviceTeardownReceipt {
        device_instance_generation: 7,
        observation_registration_generation: 11,
        notification_sequence_watermark: 0,
        teardown_generation: 1,
        ingress_in_flight_count: 0,
        reserved0: 0,
        reserved1: 0,
        reserved2: 0,
    };
    assert_eq!(
        // SAFETY: `authority` is live and `decision` is writable for this call.
        unsafe {
            osata_authority_retire_device(
                authority,
                decision.reducer_revision,
                teardown,
                &raw mut decision,
            )
        },
        RUNTIME_OK
    );
    assert_eq!(decision.kind, DECISION_DEVICE_RETIRED);
    assert_eq!(decision.has_operation, 1);
    assert_eq!(decision.operation.operation_id, operation_id);

    assert_eq!(
        // SAFETY: This deliberately exercises the FFI null guard without dereferencing null.
        unsafe { osata_authority_snapshot(std::ptr::null_mut(), &raw mut snapshot) },
        RUNTIME_NULL_POINTER
    );
    assert_eq!(
        // SAFETY: This deliberately exercises the FFI null guard without writing through null.
        unsafe { osata_authority_snapshot(authority, std::ptr::null_mut()) },
        RUNTIME_NULL_POINTER
    );

    // SAFETY: `authority` was returned by create and is destroyed exactly once after all calls.
    unsafe { osata_authority_destroy(authority) };
}
