#ifndef OPENSTEAMER_AUDIO_TRANSACTION_AUTHORITY_H
#define OPENSTEAMER_AUDIO_TRANSACTION_AUTHORITY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static const uint32_t OSATA_ABI_VERSION __attribute__((unused)) = 1;
static const uint32_t OSATA_MAX_TOMBSTONES __attribute__((unused)) = 64;

typedef struct osata_authority osata_authority_t;

typedef struct {
    uint64_t high;
    uint64_t low;
} osata_uuid_t;

static const uint32_t OSATA_CATEGORY_INVALID __attribute__((unused)) = 0;
static const uint32_t OSATA_CATEGORY_PLAYBACK __attribute__((unused)) = 1;
static const uint32_t OSATA_CATEGORY_PLAY_AND_RECORD __attribute__((unused)) = 2;
static const uint32_t OSATA_MODE_INVALID __attribute__((unused)) = 0;
static const uint32_t OSATA_MODE_DEFAULT __attribute__((unused)) = 1;

typedef struct {
    uint32_t category;
    uint32_t mode;
    uint64_t options;
    int64_t route_sharing_policy;
    uint32_t input_required;
    uint32_t reserved;
} osata_target_t;

typedef struct {
    osata_uuid_t operation_id;
    uint64_t operation_revision;
    uint64_t authority_epoch;
} osata_operation_receipt_t;

typedef struct {
    uint64_t reducer_revision;
    uint64_t authority_epoch;
    uint32_t has_blocker;
    uint32_t reserved;
    osata_operation_receipt_t blocker;
} osata_boundary_receipt_t;

typedef struct {
    osata_operation_receipt_t operation;
    uint64_t proof_revision;
} osata_proof_receipt_t;

static const uint32_t OSATA_NATIVE_OUTCOME_PENDING __attribute__((unused)) = 0;
static const uint32_t OSATA_NATIVE_OUTCOME_ACCEPTED __attribute__((unused)) = 1;
static const uint32_t OSATA_NATIVE_OUTCOME_REJECTED __attribute__((unused)) = 2;
static const uint32_t OSATA_NATIVE_OUTCOME_REVOKED __attribute__((unused)) = 3;

typedef struct {
    osata_operation_receipt_t operation;
    uint64_t authorization_generation;
    uint64_t terminal_generation;
    uint32_t outcome;
    uint32_t policy_matches_requested_target;
} osata_native_recovery_receipt_t;

static const uint32_t OSATA_DRAIN_BINDING_STATE_STAGED __attribute__((unused)) = 1;
static const uint32_t OSATA_DRAIN_BINDING_STATE_BOUND __attribute__((unused)) = 2;

typedef struct {
    osata_operation_receipt_t operation;
    uint64_t app_operation_tag_generation;
    uint64_t native_transaction_identifier;
    uint64_t transaction_configuration_generation;
    uint64_t system_audio_generation;
    uint64_t notification_sequence_watermark;
    uint64_t observation_registration_generation;
    uint64_t drain_generation;
    uint64_t device_instance_generation;
    uint32_t binding_state;
    uint32_t ingress_in_flight_count;
    uint32_t reserved0;
    uint32_t reserved1;
} osata_native_drain_receipt_t;

static const uint32_t OSATA_OBSERVATION_UNRELATED __attribute__((unused)) = 0;
static const uint32_t OSATA_OBSERVATION_TRACKED_POLICY_MISMATCH __attribute__((unused)) = 1;
static const uint32_t OSATA_OBSERVATION_EXPECTED_UNCORRELATED_TRANSACTION __attribute__((unused)) = 2;
static const uint32_t OSATA_OBSERVATION_EXPECTED_CURRENT_APP_OPERATION __attribute__((unused)) = 3;
static const uint32_t OSATA_OBSERVATION_EXPECTED_RETIRED_APP_OPERATION __attribute__((unused)) = 4;

static const uint32_t OSATA_TRANSACTION_STATE_NONE __attribute__((unused)) = 0;
static const uint32_t OSATA_TRANSACTION_STATE_PENDING __attribute__((unused)) = 1;
static const uint32_t OSATA_TRANSACTION_STATE_PREPARED __attribute__((unused)) = 2;
static const uint32_t OSATA_TRANSACTION_STATE_STARTING __attribute__((unused)) = 3;
static const uint32_t OSATA_TRANSACTION_STATE_CONSUMED __attribute__((unused)) = 4;
static const uint32_t OSATA_TRANSACTION_STATE_REJECTED __attribute__((unused)) = 5;

typedef struct {
    osata_operation_receipt_t app_operation;
    uint64_t app_operation_tag_generation;
    uint64_t device_instance_generation;
    uint64_t native_transaction_identifier;
    uint64_t notification_sequence;
    uint64_t transaction_observer_sequence_baseline;
    uint64_t transaction_configuration_generation;
    uint64_t observed_configuration_generation;
    uint64_t transaction_system_audio_generation;
    uint64_t observed_system_audio_generation;
    uint64_t observed_at_nanoseconds;
    uint64_t transaction_deadline_nanoseconds;
    uint32_t disposition;
    uint32_t transaction_state_at_ingress;
    uint32_t has_app_operation;
    uint32_t policy_tuple_is_exact;
    uint32_t transaction_evidence_is_exact;
    uint32_t input_required;
    uint32_t reserved;
    uint32_t alignment_reserved;
    osata_target_t expected_target;
    osata_target_t observed_target;
} osata_native_observation_receipt_t;

typedef struct {
    uint64_t device_instance_generation;
    uint64_t observation_registration_generation;
    uint64_t notification_sequence_watermark;
    uint64_t teardown_generation;
    uint32_t ingress_in_flight_count;
    uint32_t reserved0;
    uint32_t reserved1;
    uint32_t reserved2;
} osata_native_device_teardown_receipt_t;

static const uint32_t OSATA_PROOF_OUTCOME_ACCEPTED __attribute__((unused)) = 1;
static const uint32_t OSATA_PROOF_OUTCOME_REJECTED __attribute__((unused)) = 2;

static const uint32_t OSATA_REJECTION_STALE_REVISION __attribute__((unused)) = 1;
static const uint32_t OSATA_REJECTION_STALE_AUTHORITY __attribute__((unused)) = 2;
static const uint32_t OSATA_REJECTION_STALE_OPERATION __attribute__((unused)) = 3;
static const uint32_t OSATA_REJECTION_DUPLICATE __attribute__((unused)) = 4;
static const uint32_t OSATA_REJECTION_INVALID_INPUT __attribute__((unused)) = 5;
static const uint32_t OSATA_REJECTION_TARGET_MISMATCH __attribute__((unused)) = 6;
static const uint32_t OSATA_REJECTION_BLOCKER_NOT_ALLOWED __attribute__((unused)) = 7;
static const uint32_t OSATA_REJECTION_NO_CURRENT_OPERATION __attribute__((unused)) = 8;
static const uint32_t OSATA_REJECTION_CAPACITY_EXCEEDED __attribute__((unused)) = 9;
static const uint32_t OSATA_REJECTION_BLOCKER_REQUIRED __attribute__((unused)) = 10;
static const uint32_t OSATA_REJECTION_COUNTER_EXHAUSTED __attribute__((unused)) = 11;

static const uint32_t OSATA_IGNORE_EXACT_DUPLICATE __attribute__((unused)) = 1;
static const uint32_t OSATA_IGNORE_CURRENT_OPERATION_ALREADY_TERMINAL __attribute__((unused)) = 2;
static const uint32_t OSATA_IGNORE_RETIRED_OPERATION __attribute__((unused)) = 3;
/* Historical name: only an exact retained receipt is ignored; revision ranges are never trusted. */
static const uint32_t OSATA_IGNORE_WATERMARK_RETIRED_OPERATION __attribute__((unused)) = 4;
static const uint32_t OSATA_IGNORE_STALE_DEVICE_GENERATION __attribute__((unused)) = 5;

static const uint32_t OSATA_DECISION_REJECTED __attribute__((unused)) = 0;
static const uint32_t OSATA_DECISION_ARMED __attribute__((unused)) = 1;
static const uint32_t OSATA_DECISION_BOUNDARY_APPLIED __attribute__((unused)) = 2;
static const uint32_t OSATA_DECISION_NATIVE_ACKNOWLEDGED __attribute__((unused)) = 3;
static const uint32_t OSATA_DECISION_OBSERVATION_ACCEPTED __attribute__((unused)) = 4;
static const uint32_t OSATA_DECISION_ABORTED_UNPUBLISHED __attribute__((unused)) = 5;
static const uint32_t OSATA_DECISION_WAITING_FOR_NATIVE_ACKNOWLEDGEMENT __attribute__((unused)) = 6;
static const uint32_t OSATA_DECISION_COMPLETED __attribute__((unused)) = 7;
static const uint32_t OSATA_DECISION_FAILED_CLOSED __attribute__((unused)) = 8;
static const uint32_t OSATA_DECISION_GARBAGE_COLLECTED __attribute__((unused)) = 9;
static const uint32_t OSATA_DECISION_IGNORED __attribute__((unused)) = 10;
static const uint32_t OSATA_DECISION_DEVICE_BOUND __attribute__((unused)) = 11;
/* has_operation identifies the in-flight operation atomically fail-retired by teardown, if any. */
static const uint32_t OSATA_DECISION_DEVICE_RETIRED __attribute__((unused)) = 12;

typedef struct {
    uint32_t abi_version;
    uint32_t has_current_operation;
    uint64_t reducer_revision;
    uint64_t authority_epoch;
    uint64_t gc_watermark;
    uint64_t last_observation_sequence;
    /* Diagnostic only; never sufficient evidence that an operation receipt was retired. */
    uint64_t retired_operation_revision_watermark;
    uint64_t tombstone_count;
    uint64_t device_instance_generation;
    uint64_t observation_registration_generation;
    osata_operation_receipt_t current_operation;
} osata_snapshot_t;

typedef struct {
    uint32_t abi_version;
    uint32_t kind;
    uint32_t rejection;
    uint32_t ignore_reason;
    uint64_t reducer_revision;
    uint64_t authority_epoch;
    uint32_t has_operation;
    uint32_t has_boundary;
    uint32_t has_proof;
    uint32_t has_blocker;
    osata_operation_receipt_t operation;
    osata_boundary_receipt_t boundary;
    osata_proof_receipt_t proof;
    osata_operation_receipt_t blocker;
} osata_decision_t;

static const uint32_t OSATA_RUNTIME_OK __attribute__((unused)) = 0;
static const uint32_t OSATA_RUNTIME_NULL_POINTER __attribute__((unused)) = 1;
/* Runtime value 2 is reserved; release builds use panic=abort. */
static const uint32_t OSATA_RUNTIME_POISONED __attribute__((unused)) = 3;

uint32_t osata_abi_version(void);
osata_authority_t *osata_authority_create(uint64_t initial_authority_epoch);
void osata_authority_destroy(osata_authority_t *authority);

uint32_t osata_authority_snapshot(
    osata_authority_t *authority,
    osata_snapshot_t *output
);

uint32_t osata_authority_bind_device(
    osata_authority_t *authority,
    uint64_t expected_reducer_revision,
    uint64_t device_instance_generation,
    uint64_t observation_registration_generation,
    osata_decision_t *output
);

uint32_t osata_authority_retire_device(
    osata_authority_t *authority,
    uint64_t expected_reducer_revision,
    osata_native_device_teardown_receipt_t receipt,
    osata_decision_t *output
);

uint32_t osata_authority_arm(
    osata_authority_t *authority,
    uint64_t expected_reducer_revision,
    uint64_t observation_head,
    osata_uuid_t operation_id,
    osata_target_t target,
    osata_decision_t *output
);

uint32_t osata_authority_apply_boundary(
    osata_authority_t *authority,
    uint64_t expected_reducer_revision,
    uint64_t observation_head,
    osata_decision_t *output
);

uint32_t osata_authority_abort_unpublished(
    osata_authority_t *authority,
    uint64_t expected_reducer_revision,
    osata_operation_receipt_t operation_receipt,
    osata_decision_t *output
);

uint32_t osata_authority_arm_successor(
    osata_authority_t *authority,
    osata_boundary_receipt_t boundary_receipt,
    uint64_t observation_head,
    osata_uuid_t operation_id,
    osata_target_t target,
    osata_decision_t *output
);

uint32_t osata_authority_acknowledge_native(
    osata_authority_t *authority,
    osata_native_recovery_receipt_t receipt,
    osata_decision_t *output
);

uint32_t osata_authority_observe(
    osata_authority_t *authority,
    osata_native_observation_receipt_t receipt,
    osata_decision_t *output
);

uint32_t osata_authority_resolve_proof(
    osata_authority_t *authority,
    osata_proof_receipt_t proof_receipt,
    uint32_t proof_outcome,
    osata_decision_t *output
);

uint32_t osata_authority_collect_retired(
    osata_authority_t *authority,
    osata_native_drain_receipt_t receipt,
    osata_decision_t *output
);

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(osata_uuid_t) == 16, "osata_uuid_t ABI drift");
_Static_assert(sizeof(osata_target_t) == 32, "osata_target_t ABI drift");
_Static_assert(sizeof(osata_operation_receipt_t) == 32, "operation receipt ABI drift");
_Static_assert(sizeof(osata_boundary_receipt_t) == 56, "boundary receipt ABI drift");
_Static_assert(sizeof(osata_proof_receipt_t) == 40, "proof receipt ABI drift");
_Static_assert(sizeof(osata_native_recovery_receipt_t) == 56, "native receipt ABI drift");
_Static_assert(sizeof(osata_native_drain_receipt_t) == 112, "drain receipt ABI drift");
_Static_assert(sizeof(osata_native_observation_receipt_t) == 216, "observation ABI drift");
_Static_assert(sizeof(osata_native_device_teardown_receipt_t) == 48, "teardown ABI drift");
_Static_assert(sizeof(osata_snapshot_t) == 104, "snapshot ABI drift");
_Static_assert(sizeof(osata_decision_t) == 208, "decision ABI drift");
_Static_assert(_Alignof(osata_uuid_t) == 8, "osata_uuid_t alignment drift");
_Static_assert(_Alignof(osata_target_t) == 8, "osata_target_t alignment drift");
_Static_assert(_Alignof(osata_operation_receipt_t) == 8, "operation receipt alignment drift");
_Static_assert(_Alignof(osata_boundary_receipt_t) == 8, "boundary receipt alignment drift");
_Static_assert(_Alignof(osata_proof_receipt_t) == 8, "proof receipt alignment drift");
_Static_assert(_Alignof(osata_native_recovery_receipt_t) == 8, "native receipt alignment drift");
_Static_assert(_Alignof(osata_native_drain_receipt_t) == 8, "drain receipt alignment drift");
_Static_assert(_Alignof(osata_native_observation_receipt_t) == 8, "observation alignment drift");
_Static_assert(_Alignof(osata_native_device_teardown_receipt_t) == 8, "teardown alignment drift");
_Static_assert(_Alignof(osata_snapshot_t) == 8, "snapshot alignment drift");
_Static_assert(_Alignof(osata_decision_t) == 8, "decision alignment drift");
#endif

#ifdef __cplusplus
}
#endif

#endif
