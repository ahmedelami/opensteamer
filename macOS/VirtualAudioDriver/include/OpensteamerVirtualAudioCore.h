#ifndef OPENSTEAMER_VIRTUAL_AUDIO_CORE_H
#define OPENSTEAMER_VIRTUAL_AUDIO_CORE_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define OSVA_SAMPLE_RATE_HZ UINT64_C(48000)
#define OSVA_CHANNEL_COUNT UINT32_C(1)
#define OSVA_BYTES_PER_FRAME UINT32_C(4)
#define OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES UINT64_C(16384)
#define OSVA_MIN_RING_CAPACITY_FRAMES ((size_t)16384)
#define OSVA_PRODUCTION_RING_CAPACITY_FRAMES ((size_t)131072)
#define OSVA_INVALID_CLIENT_SLOT UINT32_MAX
#define OSVA_SNAPSHOT_MAX_ATTEMPTS 16u

typedef uint64_t (*OSVAHostClockNowFunction)(void *context);

typedef enum OSVAEndpoint {
    OSVA_ENDPOINT_VISIBLE_INPUT = 1,
    OSVA_ENDPOINT_HIDDEN_WRITER = 2
} OSVAEndpoint;

typedef enum OSVAStatus {
    OSVA_STATUS_OK = 0,
    OSVA_STATUS_INVALID_ARGUMENT,
    OSVA_STATUS_UNSUPPORTED_CONFIGURATION,
    OSVA_STATUS_ATOMIC_NOT_LOCK_FREE,
    OSVA_STATUS_LIFECYCLE_ERROR,
    OSVA_STATUS_CLIENT_ALREADY_STARTED,
    OSVA_STATUS_CLIENT_CAPACITY_EXHAUSTED,
    OSVA_STATUS_NO_ACTIVE_TIMELINE,
    OSVA_STATUS_INACTIVE_CLIENT,
    OSVA_STATUS_STALE_CLIENT_LEASE,
    OSVA_STATUS_ENDPOINT_MISMATCH,
    OSVA_STATUS_SEED_EXHAUSTED,
    OSVA_STATUS_SESSION_EXHAUSTED,
    OSVA_STATUS_CLOCK_REGRESSION,
    OSVA_STATUS_ARITHMETIC_OVERFLOW,
    OSVA_STATUS_RETRY
} OSVAStatus;

typedef struct OSVARingSlot {
    _Atomic uint64_t sequence;
    _Atomic uint64_t timeline_seed;
    _Atomic uint64_t absolute_frame;
    _Atomic uint64_t producer_session_id;
    _Atomic uint32_t producer_client_slot;
    _Atomic uint32_t sample_bits;
} OSVARingSlot;

typedef struct OSVAClientSlot {
    _Atomic uint64_t session_id;
    _Atomic uint64_t client_id;
    _Atomic uint64_t timeline_seed;
    _Atomic uint32_t endpoint;
} OSVAClientSlot;

typedef struct OSVAClientLease {
    uint64_t client_id;
    uint64_t session_id;
    uint64_t timeline_seed;
    uint32_t client_slot;
    OSVAEndpoint endpoint;
} OSVAClientLease;

typedef struct OSVACoreSnapshot {
    bool timeline_active;
    uint64_t lifecycle_sequence;
    uint64_t timeline_seed;
    uint64_t anchor_host_ticks;
    uint64_t active_client_count;
    uint64_t visible_input_client_count;
    uint64_t hidden_writer_client_count;
} OSVACoreSnapshot;

typedef struct OSVAZeroTimestamp {
    uint64_t sample_frame;
    uint64_t host_ticks;
    uint64_t seed;
} OSVAZeroTimestamp;

typedef struct OSVAWriteResult {
    size_t requested_frames;
    size_t written_frames;
    size_t contended_frames;
} OSVAWriteResult;

typedef struct OSVAReadResult {
    size_t requested_frames;
    size_t delivered_frames;
    size_t underrun_frames;
} OSVAReadResult;

typedef struct OSVACore {
    pthread_mutex_t lifecycle_mutex;
    OSVARingSlot *ring_slots;
    size_t ring_capacity_frames;
    size_t ring_index_mask;
    OSVAClientSlot *client_slots;
    size_t client_slot_count;
    OSVAHostClockNowFunction clock_now;
    void *clock_context;
    uint64_t host_ticks_per_second;
    uint64_t last_issued_seed;
    uint64_t last_issued_session_id;
    _Atomic uint64_t lifecycle_sequence;
    _Atomic uint64_t timeline_seed;
    _Atomic uint64_t anchor_host_ticks;
    _Atomic uint64_t active_client_count;
    _Atomic uint64_t visible_input_client_count;
    _Atomic uint64_t hidden_writer_client_count;
    _Atomic bool initialized;
} OSVACore;

/*
 * The caller must provide a zero-initialized OSVACore. Initialization and
 * destruction are lifecycle operations and must not run concurrently with
 * any other core operation. A second initialization without a successful
 * destroy is rejected without modifying the live core.
 */
OSVAStatus OSVACoreInitialize(
    OSVACore *core,
    OSVARingSlot *ring_slots,
    size_t ring_capacity_frames,
    OSVAClientSlot *client_slots,
    size_t client_slot_count,
    OSVAHostClockNowFunction clock_now,
    void *clock_context,
    uint64_t host_ticks_per_second,
    uint64_t initial_seed
);

OSVAStatus OSVACoreDestroy(OSVACore *core);

OSVAStatus OSVACoreStartClient(
    OSVACore *core,
    OSVAEndpoint endpoint,
    uint64_t client_id,
    OSVAClientLease *lease_out
);

OSVAStatus OSVACoreStopClient(OSVACore *core, OSVAClientLease lease);

bool OSVACoreClientLeaseIsActive(const OSVACore *core, OSVAClientLease lease);

OSVAStatus OSVACoreGetSnapshot(
    const OSVACore *core,
    OSVACoreSnapshot *snapshot_out
);

OSVAStatus OSVACoreGetZeroTimestamp(
    OSVACore *core,
    OSVAZeroTimestamp *timestamp_out
);

OSVAStatus OSVACoreGetZeroTimestampAtHostTicks(
    const OSVACore *core,
    uint64_t observed_host_ticks,
    OSVAZeroTimestamp *timestamp_out
);

OSVAStatus OSVACoreWriteFrames(
    OSVACore *core,
    OSVAClientLease writer,
    uint64_t start_frame,
    const float *samples,
    size_t frame_count,
    OSVAWriteResult *result_out
);

OSVAStatus OSVACoreReadFrames(
    OSVACore *core,
    OSVAClientLease reader,
    uint64_t start_frame,
    float *samples_out,
    size_t frame_count,
    OSVAReadResult *result_out
);

const char *OSVAStatusName(OSVAStatus status);

#endif
