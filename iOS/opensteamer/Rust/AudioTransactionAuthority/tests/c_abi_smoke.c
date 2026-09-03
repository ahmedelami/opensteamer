#include "opensteamer_audio_transaction_authority.h"

uint32_t osata_c_abi_smoke(osata_authority_t *authority) {
    osata_snapshot_t snapshot = {0};
    osata_decision_t decision = {0};
    osata_uuid_t operation_id = {1, 2};
    osata_target_t target = {
        OSATA_CATEGORY_PLAYBACK,
        OSATA_MODE_DEFAULT,
        0,
        0,
        0,
        0,
    };
    osata_boundary_receipt_t boundary = {0};
    osata_native_recovery_receipt_t recovery = {0};
    osata_native_observation_receipt_t observation = {0};
    osata_native_drain_receipt_t drain = {0};
    osata_native_device_teardown_receipt_t teardown = {0};
    osata_proof_receipt_t proof = {0};

    uint32_t status = osata_authority_snapshot(authority, &snapshot);
    status |= osata_authority_bind_device(
        authority,
        snapshot.reducer_revision,
        1,
        1,
        &decision
    );
    status |= osata_authority_retire_device(
        authority,
        decision.reducer_revision,
        teardown,
        &decision
    );
    status |= osata_authority_arm(
        authority,
        snapshot.reducer_revision,
        snapshot.last_observation_sequence,
        operation_id,
        target,
        &decision
    );
    status |= osata_authority_apply_boundary(
        authority,
        decision.reducer_revision,
        snapshot.last_observation_sequence,
        &decision
    );
    status |= osata_authority_abort_unpublished(
        authority,
        decision.reducer_revision,
        decision.operation,
        &decision
    );
    status |= osata_authority_arm_successor(
        authority,
        boundary,
        snapshot.last_observation_sequence,
        operation_id,
        target,
        &decision
    );
    status |= osata_authority_acknowledge_native(authority, recovery, &decision);
    status |= osata_authority_observe(authority, observation, &decision);
    status |= osata_authority_resolve_proof(
        authority,
        proof,
        OSATA_PROOF_OUTCOME_ACCEPTED,
        &decision
    );
    status |= osata_authority_collect_retired(authority, drain, &decision);
    return status | osata_abi_version() | OSATA_ABI_VERSION;
}
