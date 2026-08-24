#include "OpensteamerVirtualAudioCore.h"

#include <limits.h>
#include <string.h>

_Static_assert(
    OSVA_PRODUCTION_RING_CAPACITY_FRAMES >=
        OSVA_MIN_RING_CAPACITY_FRAMES,
    "production ring must satisfy the minimum zero-timestamp period"
);
_Static_assert(
    (OSVA_PRODUCTION_RING_CAPACITY_FRAMES &
     (OSVA_PRODUCTION_RING_CAPACITY_FRAMES - 1)) == 0,
    "production ring capacity must be a power of two"
);

static bool OSVAEndpointIsValid(OSVAEndpoint endpoint) {
    return endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ||
           endpoint == OSVA_ENDPOINT_HIDDEN_WRITER;
}

static bool OSVAIsPowerOfTwo(size_t value) {
    return value != 0 && (value & (value - 1)) == 0;
}

static uint64_t OSVAEndpointClientCount(
    const OSVACore *core,
    OSVAEndpoint endpoint
) {
    return atomic_load_explicit(
        endpoint == OSVA_ENDPOINT_VISIBLE_INPUT
            ? &core->visible_input_client_count
            : &core->hidden_writer_client_count,
        memory_order_acquire
    );
}

static bool OSVAAtomicsAreLockFree(
    const OSVACore *core,
    const OSVARingSlot *ring_slot,
    const OSVAClientSlot *client_slot
) {
    return atomic_is_lock_free(&core->lifecycle_sequence) &&
           atomic_is_lock_free(&core->timeline_seed) &&
           atomic_is_lock_free(&core->anchor_host_ticks) &&
           atomic_is_lock_free(&core->active_client_count) &&
           atomic_is_lock_free(&core->visible_input_client_count) &&
           atomic_is_lock_free(&core->hidden_writer_client_count) &&
           atomic_is_lock_free(&core->initialized) &&
           atomic_is_lock_free(&ring_slot->sequence) &&
           atomic_is_lock_free(&ring_slot->timeline_seed) &&
           atomic_is_lock_free(&ring_slot->absolute_frame) &&
           atomic_is_lock_free(&ring_slot->producer_session_id) &&
           atomic_is_lock_free(&ring_slot->producer_client_slot) &&
           atomic_is_lock_free(&ring_slot->sample_bits) &&
           atomic_is_lock_free(&client_slot->session_id) &&
           atomic_is_lock_free(&client_slot->client_id) &&
           atomic_is_lock_free(&client_slot->timeline_seed) &&
           atomic_is_lock_free(&client_slot->endpoint);
}

static OSVAStatus OSVAValidateInitialized(const OSVACore *core) {
    if (core == NULL) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    if (!atomic_load_explicit(&core->initialized, memory_order_acquire)) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    return OSVA_STATUS_OK;
}

static OSVAStatus OSVAReserveLifecycleMutation(
    OSVACore *core,
    uint64_t *odd_sequence_out
) {
    uint64_t sequence = atomic_load_explicit(
        &core->lifecycle_sequence,
        memory_order_relaxed
    );
    if ((sequence & UINT64_C(1)) != 0 || sequence > UINT64_MAX - 2) {
        return OSVA_STATUS_SESSION_EXHAUSTED;
    }
    *odd_sequence_out = sequence + 1;
    atomic_store_explicit(
        &core->lifecycle_sequence,
        *odd_sequence_out,
        memory_order_release
    );
    return OSVA_STATUS_OK;
}

static void OSVACommitLifecycleMutation(
    OSVACore *core,
    uint64_t odd_sequence
) {
    atomic_store_explicit(
        &core->lifecycle_sequence,
        odd_sequence + 1,
        memory_order_release
    );
}

static bool OSVAClientSlotMatchesLease(
    const OSVACore *core,
    OSVAClientLease lease
) {
    if (lease.session_id == 0 ||
        !OSVAEndpointIsValid(lease.endpoint) ||
        lease.client_slot >= core->client_slot_count) {
        return false;
    }
    const OSVAClientSlot *slot = &core->client_slots[lease.client_slot];
    const uint64_t session_id = atomic_load_explicit(
        &slot->session_id,
        memory_order_acquire
    );
    if (session_id != lease.session_id) {
        return false;
    }
    return atomic_load_explicit(&slot->client_id, memory_order_relaxed) ==
               lease.client_id &&
           atomic_load_explicit(&slot->timeline_seed, memory_order_relaxed) ==
               lease.timeline_seed &&
           atomic_load_explicit(&slot->endpoint, memory_order_relaxed) ==
               (uint32_t)lease.endpoint &&
           atomic_load_explicit(
               &core->timeline_seed,
               memory_order_acquire
           ) == lease.timeline_seed;
}

static OSVAStatus OSVAValidateLeaseForIO(
    const OSVACore *core,
    OSVAClientLease lease,
    OSVAEndpoint required_endpoint,
    uint64_t *lifecycle_sequence_out
) {
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    if (!OSVAEndpointIsValid(lease.endpoint) ||
        lease.endpoint != required_endpoint) {
        return OSVA_STATUS_ENDPOINT_MISMATCH;
    }
    uint64_t before = atomic_load_explicit(
        &core->lifecycle_sequence,
        memory_order_acquire
    );
    if ((before & UINT64_C(1)) != 0) {
        return OSVA_STATUS_RETRY;
    }
    if (!OSVAClientSlotMatchesLease(core, lease)) {
        if (lease.client_slot < core->client_slot_count &&
            atomic_load_explicit(
                &core->client_slots[lease.client_slot].session_id,
                memory_order_acquire
            ) == 0) {
            return OSVA_STATUS_INACTIVE_CLIENT;
        }
        return OSVA_STATUS_STALE_CLIENT_LEASE;
    }
    uint64_t after = atomic_load_explicit(
        &core->lifecycle_sequence,
        memory_order_acquire
    );
    if (before != after || (after & UINT64_C(1)) != 0) {
        return OSVA_STATUS_RETRY;
    }
    *lifecycle_sequence_out = before;
    return OSVA_STATUS_OK;
}

static bool OSVAFrameRangeIsRepresentable(
    uint64_t start_frame,
    size_t frame_count
) {
    if (frame_count == 0) {
        return true;
    }
    if ((uintmax_t)(frame_count - 1) > UINT64_MAX) {
        return false;
    }
    return start_frame <= UINT64_MAX - (uint64_t)(frame_count - 1);
}

static uint32_t OSVAFloatBits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float OSVAFloatFromBits(uint32_t bits) {
    float value = 0.0F;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

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
) {
    if (core == NULL || ring_slots == NULL || client_slots == NULL ||
        clock_now == NULL || host_ticks_per_second == 0 ||
        !OSVAIsPowerOfTwo(ring_capacity_frames) ||
        ring_capacity_frames < OSVA_MIN_RING_CAPACITY_FRAMES ||
        client_slot_count == 0 || client_slot_count > UINT32_MAX) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    if (atomic_load_explicit(&core->initialized, memory_order_acquire)) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }

    memset(core, 0, sizeof(*core));
    if (pthread_mutex_init(&core->lifecycle_mutex, NULL) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    core->ring_slots = ring_slots;
    core->ring_capacity_frames = ring_capacity_frames;
    core->ring_index_mask = ring_capacity_frames - 1;
    core->client_slots = client_slots;
    core->client_slot_count = client_slot_count;
    core->clock_now = clock_now;
    core->clock_context = clock_context;
    core->host_ticks_per_second = host_ticks_per_second;
    core->last_issued_seed = initial_seed;

    atomic_init(&core->lifecycle_sequence, 0);
    atomic_init(&core->timeline_seed, 0);
    atomic_init(&core->anchor_host_ticks, 0);
    atomic_init(&core->active_client_count, 0);
    atomic_init(&core->visible_input_client_count, 0);
    atomic_init(&core->hidden_writer_client_count, 0);
    atomic_init(&core->initialized, false);

    for (size_t index = 0; index < ring_capacity_frames; ++index) {
        atomic_init(&ring_slots[index].sequence, 0);
        atomic_init(&ring_slots[index].timeline_seed, 0);
        atomic_init(&ring_slots[index].absolute_frame, 0);
        atomic_init(&ring_slots[index].producer_session_id, 0);
        atomic_init(
            &ring_slots[index].producer_client_slot,
            OSVA_INVALID_CLIENT_SLOT
        );
        atomic_init(&ring_slots[index].sample_bits, 0);
    }
    for (size_t index = 0; index < client_slot_count; ++index) {
        atomic_init(&client_slots[index].session_id, 0);
        atomic_init(&client_slots[index].client_id, 0);
        atomic_init(&client_slots[index].timeline_seed, 0);
        atomic_init(&client_slots[index].endpoint, 0);
    }

    if (!OSVAAtomicsAreLockFree(core, &ring_slots[0], &client_slots[0])) {
        (void)pthread_mutex_destroy(&core->lifecycle_mutex);
        return OSVA_STATUS_ATOMIC_NOT_LOCK_FREE;
    }
    atomic_store_explicit(&core->initialized, true, memory_order_release);
    return OSVA_STATUS_OK;
}

OSVAStatus OSVACoreDestroy(OSVACore *core) {
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    if (pthread_mutex_lock(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    if (atomic_load_explicit(
            &core->active_client_count,
            memory_order_acquire
        ) != 0) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    atomic_store_explicit(&core->initialized, false, memory_order_release);
    if (pthread_mutex_unlock(&core->lifecycle_mutex) != 0 ||
        pthread_mutex_destroy(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    return OSVA_STATUS_OK;
}

OSVAStatus OSVACoreStartClient(
    OSVACore *core,
    OSVAEndpoint endpoint,
    uint64_t client_id,
    OSVAClientLease *lease_out
) {
    if (lease_out == NULL || !OSVAEndpointIsValid(endpoint)) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    memset(lease_out, 0, sizeof(*lease_out));
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    if (pthread_mutex_lock(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }

    size_t free_slot = core->client_slot_count;
    for (size_t index = 0; index < core->client_slot_count; ++index) {
        OSVAClientSlot *slot = &core->client_slots[index];
        uint64_t session_id = atomic_load_explicit(
            &slot->session_id,
            memory_order_acquire
        );
        if (session_id == 0) {
            if (free_slot == core->client_slot_count) {
                free_slot = index;
            }
            continue;
        }
        if (atomic_load_explicit(&slot->client_id, memory_order_relaxed) ==
                client_id &&
            atomic_load_explicit(&slot->endpoint, memory_order_relaxed) ==
                (uint32_t)endpoint) {
            (void)pthread_mutex_unlock(&core->lifecycle_mutex);
            return OSVA_STATUS_CLIENT_ALREADY_STARTED;
        }
    }
    if (free_slot == core->client_slot_count) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_CLIENT_CAPACITY_EXHAUSTED;
    }

    uint64_t active_count = atomic_load_explicit(
        &core->active_client_count,
        memory_order_relaxed
    );
    if (active_count == UINT64_MAX ||
        core->last_issued_session_id == UINT64_MAX) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_SESSION_EXHAUSTED;
    }
    uint64_t seed = atomic_load_explicit(
        &core->timeline_seed,
        memory_order_relaxed
    );
    uint64_t anchor = atomic_load_explicit(
        &core->anchor_host_ticks,
        memory_order_relaxed
    );
    if (active_count == 0) {
        if (core->last_issued_seed == UINT64_MAX) {
            (void)pthread_mutex_unlock(&core->lifecycle_mutex);
            return OSVA_STATUS_SEED_EXHAUSTED;
        }
        seed = core->last_issued_seed + 1;
        if (seed == 0) {
            (void)pthread_mutex_unlock(&core->lifecycle_mutex);
            return OSVA_STATUS_SEED_EXHAUSTED;
        }
        anchor = core->clock_now(core->clock_context);
    } else if (seed == 0) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }

    uint64_t odd_sequence = 0;
    status = OSVAReserveLifecycleMutation(core, &odd_sequence);
    if (status != OSVA_STATUS_OK) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return status;
    }

    if (active_count == 0) {
        core->last_issued_seed = seed;
        atomic_store_explicit(
            &core->anchor_host_ticks,
            anchor,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &core->timeline_seed,
            seed,
            memory_order_release
        );
    }
    core->last_issued_session_id += 1;
    uint64_t session_id = core->last_issued_session_id;
    OSVAClientSlot *slot = &core->client_slots[free_slot];
    atomic_store_explicit(&slot->client_id, client_id, memory_order_relaxed);
    atomic_store_explicit(&slot->timeline_seed, seed, memory_order_relaxed);
    atomic_store_explicit(
        &slot->endpoint,
        (uint32_t)endpoint,
        memory_order_relaxed
    );
    atomic_store_explicit(&slot->session_id, session_id, memory_order_release);
    atomic_store_explicit(
        &core->active_client_count,
        active_count + 1,
        memory_order_relaxed
    );
    _Atomic uint64_t *endpoint_count =
        endpoint == OSVA_ENDPOINT_VISIBLE_INPUT
            ? &core->visible_input_client_count
            : &core->hidden_writer_client_count;
    uint64_t prior_endpoint_count = atomic_load_explicit(
        endpoint_count,
        memory_order_relaxed
    );
    atomic_store_explicit(
        endpoint_count,
        prior_endpoint_count + 1,
        memory_order_relaxed
    );
    OSVACommitLifecycleMutation(core, odd_sequence);
    if (pthread_mutex_unlock(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }

    *lease_out = (OSVAClientLease){
        .client_id = client_id,
        .session_id = session_id,
        .timeline_seed = seed,
        .client_slot = (uint32_t)free_slot,
        .endpoint = endpoint,
    };
    return OSVA_STATUS_OK;
}

OSVAStatus OSVACoreStopClient(OSVACore *core, OSVAClientLease lease) {
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    if (pthread_mutex_lock(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    if (!OSVAClientSlotMatchesLease(core, lease)) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_STALE_CLIENT_LEASE;
    }
    uint64_t active_count = atomic_load_explicit(
        &core->active_client_count,
        memory_order_relaxed
    );
    uint64_t endpoint_count = OSVAEndpointClientCount(core, lease.endpoint);
    if (active_count == 0 || endpoint_count == 0) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    uint64_t odd_sequence = 0;
    status = OSVAReserveLifecycleMutation(core, &odd_sequence);
    if (status != OSVA_STATUS_OK) {
        (void)pthread_mutex_unlock(&core->lifecycle_mutex);
        return status;
    }

    OSVAClientSlot *slot = &core->client_slots[lease.client_slot];
    atomic_store_explicit(&slot->session_id, 0, memory_order_release);
    atomic_store_explicit(
        &core->active_client_count,
        active_count - 1,
        memory_order_relaxed
    );
    _Atomic uint64_t *count =
        lease.endpoint == OSVA_ENDPOINT_VISIBLE_INPUT
            ? &core->visible_input_client_count
            : &core->hidden_writer_client_count;
    atomic_store_explicit(count, endpoint_count - 1, memory_order_relaxed);
    if (active_count == 1) {
        atomic_store_explicit(&core->timeline_seed, 0, memory_order_release);
        atomic_store_explicit(
            &core->anchor_host_ticks,
            0,
            memory_order_relaxed
        );
    }
    OSVACommitLifecycleMutation(core, odd_sequence);
    if (pthread_mutex_unlock(&core->lifecycle_mutex) != 0) {
        return OSVA_STATUS_LIFECYCLE_ERROR;
    }
    return OSVA_STATUS_OK;
}

bool OSVACoreClientLeaseIsActive(
    const OSVACore *core,
    OSVAClientLease lease
) {
    uint64_t sequence = 0;
    return OSVAValidateLeaseForIO(
               core,
               lease,
               lease.endpoint,
               &sequence
           ) == OSVA_STATUS_OK;
}

OSVAStatus OSVACoreGetSnapshot(
    const OSVACore *core,
    OSVACoreSnapshot *snapshot_out
) {
    if (snapshot_out == NULL) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    memset(snapshot_out, 0, sizeof(*snapshot_out));
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    for (unsigned attempt = 0; attempt < OSVA_SNAPSHOT_MAX_ATTEMPTS; ++attempt) {
        uint64_t before = atomic_load_explicit(
            &core->lifecycle_sequence,
            memory_order_acquire
        );
        if ((before & UINT64_C(1)) != 0) {
            continue;
        }
        OSVACoreSnapshot snapshot = {
            .timeline_active = atomic_load_explicit(
                &core->timeline_seed,
                memory_order_acquire
            ) != 0,
            .lifecycle_sequence = before,
            .timeline_seed = atomic_load_explicit(
                &core->timeline_seed,
                memory_order_relaxed
            ),
            .anchor_host_ticks = atomic_load_explicit(
                &core->anchor_host_ticks,
                memory_order_relaxed
            ),
            .active_client_count = atomic_load_explicit(
                &core->active_client_count,
                memory_order_relaxed
            ),
            .visible_input_client_count = atomic_load_explicit(
                &core->visible_input_client_count,
                memory_order_relaxed
            ),
            .hidden_writer_client_count = atomic_load_explicit(
                &core->hidden_writer_client_count,
                memory_order_relaxed
            ),
        };
        uint64_t after = atomic_load_explicit(
            &core->lifecycle_sequence,
            memory_order_acquire
        );
        if (before == after && (after & UINT64_C(1)) == 0) {
            *snapshot_out = snapshot;
            return OSVA_STATUS_OK;
        }
    }
    return OSVA_STATUS_RETRY;
}

OSVAStatus OSVACoreGetZeroTimestampAtHostTicks(
    const OSVACore *core,
    uint64_t observed_host_ticks,
    OSVAZeroTimestamp *timestamp_out
) {
    if (timestamp_out == NULL) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    memset(timestamp_out, 0, sizeof(*timestamp_out));
    OSVACoreSnapshot snapshot;
    OSVAStatus status = OSVACoreGetSnapshot(core, &snapshot);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    if (!snapshot.timeline_active || snapshot.timeline_seed == 0) {
        return OSVA_STATUS_NO_ACTIVE_TIMELINE;
    }
    if (observed_host_ticks < snapshot.anchor_host_ticks) {
        return OSVA_STATUS_CLOCK_REGRESSION;
    }
    const uint64_t elapsed_ticks =
        observed_host_ticks - snapshot.anchor_host_ticks;
    const __uint128_t frame_numerator =
        (__uint128_t)elapsed_ticks * OSVA_SAMPLE_RATE_HZ;
    const __uint128_t elapsed_frames_wide =
        frame_numerator / core->host_ticks_per_second;
    if (elapsed_frames_wide > UINT64_MAX) {
        return OSVA_STATUS_ARITHMETIC_OVERFLOW;
    }
    const uint64_t elapsed_frames = (uint64_t)elapsed_frames_wide;
    const uint64_t period_index =
        elapsed_frames / OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES;
    if (period_index >
        UINT64_MAX / OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES) {
        return OSVA_STATUS_ARITHMETIC_OVERFLOW;
    }
    const uint64_t sample_frame =
        period_index * OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES;
    const __uint128_t host_numerator =
        (__uint128_t)sample_frame * core->host_ticks_per_second;
    const __uint128_t host_offset_wide =
        (host_numerator + OSVA_SAMPLE_RATE_HZ - 1) /
        OSVA_SAMPLE_RATE_HZ;
    if (host_offset_wide > UINT64_MAX) {
        return OSVA_STATUS_ARITHMETIC_OVERFLOW;
    }
    const uint64_t host_offset = (uint64_t)host_offset_wide;
    if (snapshot.anchor_host_ticks > UINT64_MAX - host_offset) {
        return OSVA_STATUS_ARITHMETIC_OVERFLOW;
    }
    if (atomic_load_explicit(
            &core->lifecycle_sequence,
            memory_order_acquire
        ) != snapshot.lifecycle_sequence ||
        atomic_load_explicit(&core->timeline_seed, memory_order_acquire) !=
            snapshot.timeline_seed) {
        return OSVA_STATUS_RETRY;
    }
    *timestamp_out = (OSVAZeroTimestamp){
        .sample_frame = sample_frame,
        .host_ticks = snapshot.anchor_host_ticks + host_offset,
        .seed = snapshot.timeline_seed,
        .lifecycle_sequence = snapshot.lifecycle_sequence,
    };
    return OSVA_STATUS_OK;
}

OSVAStatus OSVACoreGetZeroTimestamp(
    OSVACore *core,
    OSVAZeroTimestamp *timestamp_out
) {
    OSVAStatus status = OSVAValidateInitialized(core);
    if (status != OSVA_STATUS_OK) {
        return status;
    }
    return OSVACoreGetZeroTimestampAtHostTicks(
        core,
        core->clock_now(core->clock_context),
        timestamp_out
    );
}

OSVAStatus OSVACoreWriteFrames(
    OSVACore *core,
    OSVAClientLease writer,
    uint64_t start_frame,
    const float *samples,
    size_t frame_count,
    OSVAWriteResult *result_out
) {
    if (result_out == NULL ||
        (frame_count > 0 && samples == NULL) ||
        frame_count > SIZE_MAX / sizeof(*samples) ||
        !OSVAFrameRangeIsRepresentable(start_frame, frame_count)) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    *result_out = (OSVAWriteResult){
        .requested_frames = frame_count,
    };
    uint64_t lifecycle_sequence = 0;
    OSVAStatus status = OSVAValidateLeaseForIO(
        core,
        writer,
        OSVA_ENDPOINT_HIDDEN_WRITER,
        &lifecycle_sequence
    );
    if (status != OSVA_STATUS_OK) {
        return status;
    }

    bool has_last_transferred_frame = false;
    uint64_t last_transferred_absolute_frame = 0;

    for (size_t index = 0; index < frame_count; ++index) {
        const uint64_t absolute_frame = start_frame + (uint64_t)index;
        OSVARingSlot *slot =
            &core->ring_slots[absolute_frame & core->ring_index_mask];
        uint64_t observed = atomic_load_explicit(
            &slot->sequence,
            memory_order_relaxed
        );
        if ((observed & UINT64_C(1)) != 0) {
            result_out->contended_frames += 1;
            continue;
        }
        if (observed > UINT64_MAX - 2) {
            /* Never reuse an old publication sequence (ABA). */
            result_out->contended_frames += 1;
            continue;
        }
        uint64_t writing_sequence = observed + 1;
        if (!atomic_compare_exchange_strong_explicit(
                &slot->sequence,
                &observed,
                writing_sequence,
                memory_order_acq_rel,
                memory_order_relaxed
            )) {
            result_out->contended_frames += 1;
            continue;
        }
        atomic_store_explicit(
            &slot->timeline_seed,
            writer.timeline_seed,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &slot->absolute_frame,
            absolute_frame,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &slot->producer_session_id,
            writer.session_id,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &slot->producer_client_slot,
            writer.client_slot,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &slot->sample_bits,
            OSVAFloatBits(samples[index]),
            memory_order_relaxed
        );
        atomic_store_explicit(
            &slot->sequence,
            writing_sequence + 1,
            memory_order_release
        );
        result_out->written_frames += 1;
        has_last_transferred_frame = true;
        last_transferred_absolute_frame = absolute_frame;
    }

    if (has_last_transferred_frame) {
        result_out->has_last_transferred_frame = true;
        result_out->last_transferred_timeline_seed = writer.timeline_seed;
        result_out->last_transferred_session_id = writer.session_id;
        result_out->last_transferred_absolute_frame =
            last_transferred_absolute_frame;
    }

    if (atomic_load_explicit(
            &core->lifecycle_sequence,
            memory_order_acquire
        ) != lifecycle_sequence ||
        !OSVAClientSlotMatchesLease(core, writer)) {
        return OSVA_STATUS_RETRY;
    }
    return OSVA_STATUS_OK;
}

static bool OSVAProducerSessionIsActive(
    const OSVACore *core,
    uint32_t producer_client_slot,
    uint64_t producer_session_id,
    uint64_t timeline_seed
) {
    if (producer_client_slot >= core->client_slot_count ||
        producer_session_id == 0) {
        return false;
    }
    const OSVAClientSlot *slot = &core->client_slots[producer_client_slot];
    if (atomic_load_explicit(&slot->session_id, memory_order_acquire) !=
        producer_session_id) {
        return false;
    }
    return atomic_load_explicit(&slot->endpoint, memory_order_relaxed) ==
               OSVA_ENDPOINT_HIDDEN_WRITER &&
           atomic_load_explicit(
               &slot->timeline_seed,
               memory_order_relaxed
           ) == timeline_seed;
}

OSVAStatus OSVACoreReadFrames(
    OSVACore *core,
    OSVAClientLease reader,
    uint64_t start_frame,
    float *samples_out,
    size_t frame_count,
    OSVAReadResult *result_out
) {
    if (result_out == NULL ||
        (frame_count > 0 && samples_out == NULL) ||
        frame_count > SIZE_MAX / sizeof(*samples_out) ||
        !OSVAFrameRangeIsRepresentable(start_frame, frame_count)) {
        return OSVA_STATUS_INVALID_ARGUMENT;
    }
    *result_out = (OSVAReadResult){
        .requested_frames = frame_count,
        .underrun_frames = frame_count,
    };
    if (frame_count > 0) {
        memset(samples_out, 0, frame_count * sizeof(*samples_out));
    }
    uint64_t lifecycle_sequence = 0;
    OSVAStatus status = OSVAValidateLeaseForIO(
        core,
        reader,
        OSVA_ENDPOINT_VISIBLE_INPUT,
        &lifecycle_sequence
    );
    if (status != OSVA_STATUS_OK) {
        return status;
    }

    bool has_last_transferred_frame = false;
    uint64_t last_transferred_timeline_seed = 0;
    uint64_t last_transferred_session_id = 0;
    uint64_t last_transferred_absolute_frame = 0;

    for (size_t index = 0; index < frame_count; ++index) {
        const uint64_t absolute_frame = start_frame + (uint64_t)index;
        const OSVARingSlot *slot =
            &core->ring_slots[absolute_frame & core->ring_index_mask];
        const uint64_t before = atomic_load_explicit(
            &slot->sequence,
            memory_order_acquire
        );
        if (before == 0 || (before & UINT64_C(1)) != 0) {
            continue;
        }
        const uint64_t timeline_seed = atomic_load_explicit(
            &slot->timeline_seed,
            memory_order_relaxed
        );
        const uint64_t stored_frame = atomic_load_explicit(
            &slot->absolute_frame,
            memory_order_relaxed
        );
        const uint64_t producer_session_id = atomic_load_explicit(
            &slot->producer_session_id,
            memory_order_relaxed
        );
        const uint32_t producer_client_slot = atomic_load_explicit(
            &slot->producer_client_slot,
            memory_order_relaxed
        );
        const uint32_t sample_bits = atomic_load_explicit(
            &slot->sample_bits,
            memory_order_relaxed
        );
        const uint64_t after = atomic_load_explicit(
            &slot->sequence,
            memory_order_acquire
        );
        if (before != after || (after & UINT64_C(1)) != 0 ||
            timeline_seed != reader.timeline_seed ||
            stored_frame != absolute_frame ||
            !OSVAProducerSessionIsActive(
                core,
                producer_client_slot,
                producer_session_id,
                timeline_seed
            )) {
            continue;
        }
        samples_out[index] = OSVAFloatFromBits(sample_bits);
        result_out->delivered_frames += 1;
        result_out->underrun_frames -= 1;
        has_last_transferred_frame = true;
        last_transferred_timeline_seed = timeline_seed;
        last_transferred_session_id = producer_session_id;
        last_transferred_absolute_frame = absolute_frame;
    }

    if (has_last_transferred_frame) {
        result_out->has_last_transferred_frame = true;
        result_out->last_transferred_timeline_seed =
            last_transferred_timeline_seed;
        result_out->last_transferred_session_id =
            last_transferred_session_id;
        result_out->last_transferred_absolute_frame =
            last_transferred_absolute_frame;
    }

    if (atomic_load_explicit(
            &core->lifecycle_sequence,
            memory_order_acquire
        ) != lifecycle_sequence ||
        !OSVAClientSlotMatchesLease(core, reader)) {
        if (frame_count > 0) {
            memset(samples_out, 0, frame_count * sizeof(*samples_out));
        }
        result_out->delivered_frames = 0;
        result_out->underrun_frames = frame_count;
        result_out->has_last_transferred_frame = false;
        result_out->last_transferred_timeline_seed = 0;
        result_out->last_transferred_session_id = 0;
        result_out->last_transferred_absolute_frame = 0;
        return OSVA_STATUS_RETRY;
    }
    return OSVA_STATUS_OK;
}

const char *OSVAStatusName(OSVAStatus status) {
    switch (status) {
        case OSVA_STATUS_OK:
            return "ok";
        case OSVA_STATUS_INVALID_ARGUMENT:
            return "invalid_argument";
        case OSVA_STATUS_UNSUPPORTED_CONFIGURATION:
            return "unsupported_configuration";
        case OSVA_STATUS_ATOMIC_NOT_LOCK_FREE:
            return "atomic_not_lock_free";
        case OSVA_STATUS_LIFECYCLE_ERROR:
            return "lifecycle_error";
        case OSVA_STATUS_CLIENT_ALREADY_STARTED:
            return "client_already_started";
        case OSVA_STATUS_CLIENT_CAPACITY_EXHAUSTED:
            return "client_capacity_exhausted";
        case OSVA_STATUS_NO_ACTIVE_TIMELINE:
            return "no_active_timeline";
        case OSVA_STATUS_INACTIVE_CLIENT:
            return "inactive_client";
        case OSVA_STATUS_STALE_CLIENT_LEASE:
            return "stale_client_lease";
        case OSVA_STATUS_ENDPOINT_MISMATCH:
            return "endpoint_mismatch";
        case OSVA_STATUS_SEED_EXHAUSTED:
            return "seed_exhausted";
        case OSVA_STATUS_SESSION_EXHAUSTED:
            return "session_exhausted";
        case OSVA_STATUS_CLOCK_REGRESSION:
            return "clock_regression";
        case OSVA_STATUS_ARITHMETIC_OVERFLOW:
            return "arithmetic_overflow";
        case OSVA_STATUS_RETRY:
            return "retry";
    }
    return "unknown";
}
