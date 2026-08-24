#include "OpensteamerVirtualAudioCore.h"

#include <float.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_COUNT(values) (sizeof(values) / sizeof((values)[0]))

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);     \
      return false;                                                            \
    }                                                                          \
  } while (0)

#define CHECK_STATUS(expression, expected_status)                              \
  do {                                                                         \
    const OSVAStatus osva_actual_status = (expression);                        \
    const OSVAStatus osva_expected_status = (expected_status);                 \
    if (osva_actual_status != osva_expected_status) {                          \
      fprintf(stderr, "FAIL %s:%d: %s returned %s, expected %s\n", __FILE__,   \
              __LINE__, #expression, OSVAStatusName(osva_actual_status),       \
              OSVAStatusName(osva_expected_status));                           \
      return false;                                                            \
    }                                                                          \
  } while (0)

enum {
  kGuardBytes = 64,
  kDefaultClientSlots = 8,
  kRestartCount = 1000,
  kConcurrentFrameCount = 128,
  kConcurrentWriterIterations = 1000,
  kConcurrentReaderIterations = 2500,
  kLifecycleIterations = 500,
};

static const unsigned char kLeadingGuardByte = 0xA5;
static const unsigned char kTrailingGuardByte = 0x5A;

typedef struct TestClock {
  _Atomic uint64_t now;
  _Atomic uint64_t call_count;
} TestClock;

typedef struct GuardedAllocation {
  unsigned char *allocation;
  void *payload;
  size_t payload_size;
} GuardedAllocation;

typedef struct TestFixture {
  OSVACore core;
  TestClock clock;
  GuardedAllocation ring_allocation;
  GuardedAllocation client_allocation;
  OSVARingSlot *ring_slots;
  OSVAClientSlot *client_slots;
  size_t ring_capacity_frames;
  size_t client_slot_count;
  bool initialized;
} TestFixture;

typedef struct GuardedSamples {
  uint32_t leading[4];
  float samples[32];
  uint32_t trailing[4];
} GuardedSamples;

static uint64_t TestClockNow(void *context) {
  TestClock *clock = context;
  (void)atomic_fetch_add_explicit(&clock->call_count, UINT64_C(1),
                                  memory_order_relaxed);
  return atomic_load_explicit(&clock->now, memory_order_relaxed);
}

static void TestClockSet(TestClock *clock, uint64_t now) {
  atomic_store_explicit(&clock->now, now, memory_order_relaxed);
}

static uint64_t TestClockCallCount(const TestClock *clock) {
  return atomic_load_explicit(&clock->call_count, memory_order_relaxed);
}

static bool GuardedAllocationCreate(GuardedAllocation *guarded,
                                    size_t payload_size) {
  if (guarded == NULL || payload_size > SIZE_MAX - (2U * kGuardBytes)) {
    return false;
  }
  const size_t allocation_size = payload_size + (2U * kGuardBytes);
  unsigned char *allocation = malloc(allocation_size);
  if (allocation == NULL) {
    return false;
  }
  memset(allocation, kLeadingGuardByte, kGuardBytes);
  memset(allocation + kGuardBytes, 0xCC, payload_size);
  memset(allocation + kGuardBytes + payload_size, kTrailingGuardByte,
         kGuardBytes);
  *guarded = (GuardedAllocation){
      .allocation = allocation,
      .payload = allocation + kGuardBytes,
      .payload_size = payload_size,
  };
  return true;
}

static bool GuardedAllocationIsIntact(const GuardedAllocation *guarded) {
  if (guarded == NULL || guarded->allocation == NULL) {
    return false;
  }
  for (size_t index = 0; index < kGuardBytes; ++index) {
    if (guarded->allocation[index] != kLeadingGuardByte) {
      return false;
    }
    if (guarded->allocation[kGuardBytes + guarded->payload_size + index] !=
        kTrailingGuardByte) {
      return false;
    }
  }
  return true;
}

static void GuardedAllocationRelease(GuardedAllocation *guarded) {
  if (guarded != NULL) {
    free(guarded->allocation);
    memset(guarded, 0, sizeof(*guarded));
  }
}

static bool FixtureInitialize(TestFixture *fixture, size_t ring_capacity_frames,
                              size_t client_slot_count,
                              uint64_t host_ticks_per_second,
                              uint64_t initial_seed, uint64_t initial_clock) {
  if (fixture == NULL ||
      ring_capacity_frames > SIZE_MAX / sizeof(OSVARingSlot) ||
      client_slot_count > SIZE_MAX / sizeof(OSVAClientSlot)) {
    return false;
  }
  memset(fixture, 0, sizeof(*fixture));
  atomic_init(&fixture->clock.now, initial_clock);
  atomic_init(&fixture->clock.call_count, 0);
  if (!GuardedAllocationCreate(&fixture->ring_allocation,
                               ring_capacity_frames * sizeof(OSVARingSlot)) ||
      !GuardedAllocationCreate(&fixture->client_allocation,
                               client_slot_count * sizeof(OSVAClientSlot))) {
    GuardedAllocationRelease(&fixture->ring_allocation);
    GuardedAllocationRelease(&fixture->client_allocation);
    return false;
  }
  fixture->ring_slots = fixture->ring_allocation.payload;
  fixture->client_slots = fixture->client_allocation.payload;
  fixture->ring_capacity_frames = ring_capacity_frames;
  fixture->client_slot_count = client_slot_count;
  const OSVAStatus status = OSVACoreInitialize(
      &fixture->core, fixture->ring_slots, ring_capacity_frames,
      fixture->client_slots, client_slot_count, TestClockNow, &fixture->clock,
      host_ticks_per_second, initial_seed);
  if (status != OSVA_STATUS_OK) {
    fprintf(stderr, "FixtureInitialize: OSVACoreInitialize returned %s\n",
            OSVAStatusName(status));
    GuardedAllocationRelease(&fixture->ring_allocation);
    GuardedAllocationRelease(&fixture->client_allocation);
    return false;
  }
  fixture->initialized = true;
  return true;
}

static bool FixtureStorageIsIntact(const TestFixture *fixture) {
  return GuardedAllocationIsIntact(&fixture->ring_allocation) &&
         GuardedAllocationIsIntact(&fixture->client_allocation);
}

static bool FixtureDestroy(TestFixture *fixture) {
  bool success = true;
  if (fixture->initialized) {
    const OSVAStatus status = OSVACoreDestroy(&fixture->core);
    if (status != OSVA_STATUS_OK) {
      fprintf(stderr, "FixtureDestroy: OSVACoreDestroy returned %s\n",
              OSVAStatusName(status));
      success = false;
    } else {
      fixture->initialized = false;
    }
  }
  if (!FixtureStorageIsIntact(fixture)) {
    fprintf(stderr, "FixtureDestroy: guarded core storage was modified\n");
    success = false;
  }
  GuardedAllocationRelease(&fixture->ring_allocation);
  GuardedAllocationRelease(&fixture->client_allocation);
  return success;
}

static bool SnapshotEqual(const OSVACoreSnapshot *left,
                          const OSVACoreSnapshot *right) {
  return left->timeline_active == right->timeline_active &&
         left->lifecycle_sequence == right->lifecycle_sequence &&
         left->timeline_seed == right->timeline_seed &&
         left->anchor_host_ticks == right->anchor_host_ticks &&
         left->active_client_count == right->active_client_count &&
         left->visible_input_client_count ==
             right->visible_input_client_count &&
         left->hidden_writer_client_count == right->hidden_writer_client_count;
}

static uint32_t FloatBits(float value) {
  uint32_t bits = 0;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

static float FloatFromBits(uint32_t bits) {
  float value = 0.0F;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static void GuardedSamplesInitialize(GuardedSamples *buffer,
                                     uint32_t sample_bits) {
  for (size_t index = 0; index < ARRAY_COUNT(buffer->leading); ++index) {
    buffer->leading[index] = UINT32_C(0x13579BDF);
    buffer->trailing[index] = UINT32_C(0x2468ACE0);
  }
  for (size_t index = 0; index < ARRAY_COUNT(buffer->samples); ++index) {
    buffer->samples[index] = FloatFromBits(sample_bits);
  }
}

static bool GuardedSamplesCanariesAreIntact(const GuardedSamples *buffer) {
  for (size_t index = 0; index < ARRAY_COUNT(buffer->leading); ++index) {
    if (buffer->leading[index] != UINT32_C(0x13579BDF) ||
        buffer->trailing[index] != UINT32_C(0x2468ACE0)) {
      return false;
    }
  }
  return true;
}

static bool SamplesHaveBits(const float *samples, const uint32_t *expected_bits,
                            size_t frame_count) {
  for (size_t index = 0; index < frame_count; ++index) {
    if (FloatBits(samples[index]) != expected_bits[index]) {
      fprintf(stderr,
              "sample %zu bits 0x%08" PRIx32 ", expected 0x%08" PRIx32 "\n",
              index, FloatBits(samples[index]), expected_bits[index]);
      return false;
    }
  }
  return true;
}

static bool SamplesArePositiveZero(const float *samples, size_t frame_count) {
  for (size_t index = 0; index < frame_count; ++index) {
    if (FloatBits(samples[index]) != UINT32_C(0)) {
      return false;
    }
  }
  return true;
}

static bool CheckSnapshot(const TestFixture *fixture, bool timeline_active,
                          uint64_t sequence, uint64_t seed, uint64_t anchor,
                          uint64_t active, uint64_t visible, uint64_t writer) {
  OSVACoreSnapshot snapshot;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture->core, &snapshot), OSVA_STATUS_OK);
  CHECK(snapshot.timeline_active == timeline_active);
  CHECK(snapshot.lifecycle_sequence == sequence);
  CHECK(snapshot.timeline_seed == seed);
  CHECK(snapshot.anchor_host_ticks == anchor);
  CHECK(snapshot.active_client_count == active);
  CHECK(snapshot.visible_input_client_count == visible);
  CHECK(snapshot.hidden_writer_client_count == writer);
  return true;
}

static bool TestConstantsInitializationAndStatusNames(void) {
  CHECK(OSVA_SAMPLE_RATE_HZ == UINT64_C(48000));
  CHECK(OSVA_CHANNEL_COUNT == UINT32_C(1));
  CHECK(OSVA_BYTES_PER_FRAME == UINT32_C(4));
  CHECK(OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES == UINT64_C(16384));
  CHECK(OSVA_PRODUCTION_RING_CAPACITY_FRAMES == (size_t)131072);
  CHECK(OSVA_MIN_RING_CAPACITY_FRAMES == (size_t)16384);
  CHECK((OSVA_PRODUCTION_RING_CAPACITY_FRAMES &
         (OSVA_PRODUCTION_RING_CAPACITY_FRAMES - 1)) == 0);

  const struct {
    OSVAStatus status;
    const char *name;
  } statuses[] = {
      {OSVA_STATUS_OK, "ok"},
      {OSVA_STATUS_INVALID_ARGUMENT, "invalid_argument"},
      {OSVA_STATUS_UNSUPPORTED_CONFIGURATION, "unsupported_configuration"},
      {OSVA_STATUS_ATOMIC_NOT_LOCK_FREE, "atomic_not_lock_free"},
      {OSVA_STATUS_LIFECYCLE_ERROR, "lifecycle_error"},
      {OSVA_STATUS_CLIENT_ALREADY_STARTED, "client_already_started"},
      {OSVA_STATUS_CLIENT_CAPACITY_EXHAUSTED, "client_capacity_exhausted"},
      {OSVA_STATUS_NO_ACTIVE_TIMELINE, "no_active_timeline"},
      {OSVA_STATUS_INACTIVE_CLIENT, "inactive_client"},
      {OSVA_STATUS_STALE_CLIENT_LEASE, "stale_client_lease"},
      {OSVA_STATUS_ENDPOINT_MISMATCH, "endpoint_mismatch"},
      {OSVA_STATUS_SEED_EXHAUSTED, "seed_exhausted"},
      {OSVA_STATUS_SESSION_EXHAUSTED, "session_exhausted"},
      {OSVA_STATUS_CLOCK_REGRESSION, "clock_regression"},
      {OSVA_STATUS_ARITHMETIC_OVERFLOW, "arithmetic_overflow"},
      {OSVA_STATUS_RETRY, "retry"},
  };
  for (size_t index = 0; index < ARRAY_COUNT(statuses); ++index) {
    CHECK(strcmp(OSVAStatusName(statuses[index].status),
                 statuses[index].name) == 0);
  }
  CHECK(strcmp(OSVAStatusName((OSVAStatus)999), "unknown") == 0);

  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES,
                          kDefaultClientSlots, OSVA_SAMPLE_RATE_HZ, 0, 77));
  CHECK(CheckSnapshot(&fixture, false, 0, 0, 0, 0, 0, 0));
  OSVACoreSnapshot before_duplicate_initialize;
  CHECK_STATUS(
      OSVACoreGetSnapshot(&fixture.core, &before_duplicate_initialize),
      OSVA_STATUS_OK);
  CHECK_STATUS(
      OSVACoreInitialize(
          &fixture.core, fixture.ring_slots, fixture.ring_capacity_frames,
          fixture.client_slots, fixture.client_slot_count, TestClockNow,
          &fixture.clock, OSVA_SAMPLE_RATE_HZ, 0),
      OSVA_STATUS_LIFECYCLE_ERROR);
  OSVACoreSnapshot after_duplicate_initialize;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture.core, &after_duplicate_initialize),
               OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&before_duplicate_initialize,
                      &after_duplicate_initialize));
  OSVAZeroTimestamp timestamp = {
      .sample_frame = 1,
      .host_ticks = 2,
      .seed = 3,
  };
  CHECK_STATUS(
      OSVACoreGetZeroTimestampAtHostTicks(&fixture.core, 77, &timestamp),
      OSVA_STATUS_NO_ACTIVE_TIMELINE);
  CHECK(timestamp.sample_frame == 0);
  CHECK(timestamp.host_ticks == 0);
  CHECK(timestamp.seed == 0);
  CHECK(!OSVACoreClientLeaseIsActive(&fixture.core, (OSVAClientLease){0}));
  CHECK(FixtureStorageIsIntact(&fixture));
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool ExerciseStartOrder(OSVAEndpoint first_endpoint,
                               OSVAEndpoint second_endpoint) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 4,
                          OSVA_SAMPLE_RATE_HZ, 9, 1000));

  OSVAClientLease first;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, first_endpoint, 100, &first),
               OSVA_STATUS_OK);
  CHECK(first.timeline_seed == 10);
  CHECK(first.session_id == 1);
  CHECK(OSVACoreClientLeaseIsActive(&fixture.core, first));
  CHECK(CheckSnapshot(&fixture, true, 2, 10, 1000, 1,
                      first_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ? 1 : 0,
                      first_endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 1 : 0));

  TestClockSet(&fixture.clock, 2000);
  OSVAClientLease second;
  CHECK_STATUS(
      OSVACoreStartClient(&fixture.core, second_endpoint, 100, &second),
      OSVA_STATUS_OK);
  CHECK(second.timeline_seed == first.timeline_seed);
  CHECK(second.session_id == 2);
  CHECK(CheckSnapshot(&fixture, true, 4, 10, 1000, 2, 1, 1));

  OSVAClientLease third;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, first_endpoint, 300, &third),
               OSVA_STATUS_OK);
  CHECK(third.timeline_seed == 10);
  CHECK(third.session_id == 3);
  CHECK(CheckSnapshot(&fixture, true, 6, 10, 1000, 3,
                      first_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ? 2 : 1,
                      first_endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 2 : 1));

  OSVACoreSnapshot before_duplicate;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture.core, &before_duplicate),
               OSVA_STATUS_OK);
  OSVAClientLease rejected = {
      .client_id = UINT64_MAX,
      .session_id = UINT64_MAX,
      .timeline_seed = UINT64_MAX,
      .client_slot = UINT32_MAX,
      .endpoint = OSVA_ENDPOINT_HIDDEN_WRITER,
  };
  CHECK_STATUS(
      OSVACoreStartClient(&fixture.core, first_endpoint, 100, &rejected),
      OSVA_STATUS_CLIENT_ALREADY_STARTED);
  CHECK(rejected.client_id == 0);
  CHECK(rejected.session_id == 0);
  CHECK(rejected.timeline_seed == 0);
  CHECK(rejected.client_slot == 0);
  CHECK(rejected.endpoint == 0);
  OSVACoreSnapshot after_duplicate;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture.core, &after_duplicate),
               OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&before_duplicate, &after_duplicate));

  CHECK_STATUS(OSVACoreStopClient(&fixture.core, second), OSVA_STATUS_OK);
  CHECK(CheckSnapshot(&fixture, true, 8, 10, 1000, 2,
                      first_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ? 2 : 0,
                      first_endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 2 : 0));
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, third), OSVA_STATUS_OK);
  CHECK(CheckSnapshot(&fixture, true, 10, 10, 1000, 1,
                      first_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ? 1 : 0,
                      first_endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 1 : 0));
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, first), OSVA_STATUS_OK);
  CHECK(CheckSnapshot(&fixture, false, 12, 0, 0, 0, 0, 0));
  CHECK(!OSVACoreClientLeaseIsActive(&fixture.core, first));
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestVisibleFirstWriterFirstJoinsAndLeaves(void) {
  CHECK(ExerciseStartOrder(OSVA_ENDPOINT_VISIBLE_INPUT,
                           OSVA_ENDPOINT_HIDDEN_WRITER));
  CHECK(ExerciseStartOrder(OSVA_ENDPOINT_HIDDEN_WRITER,
                           OSVA_ENDPOINT_VISIBLE_INPUT));
  return true;
}

static bool TestLeaseRejectionAndCapacity(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 0, 500));
  OSVAClientLease reader;
  OSVAClientLease writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   11, &reader),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   12, &writer),
               OSVA_STATUS_OK);
  OSVACoreSnapshot full_snapshot;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture.core, &full_snapshot),
               OSVA_STATUS_OK);
  OSVAClientLease rejected;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   13, &rejected),
               OSVA_STATUS_CLIENT_CAPACITY_EXHAUSTED);
  OSVACoreSnapshot after_capacity;
  CHECK_STATUS(OSVACoreGetSnapshot(&fixture.core, &after_capacity),
               OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&full_snapshot, &after_capacity));

  float one = 1.0F;
  float destination = 9.0F;
  OSVAWriteResult write_result;
  OSVAReadResult read_result;
  CHECK_STATUS(
      OSVACoreWriteFrames(&fixture.core, reader, 0, &one, 1, &write_result),
      OSVA_STATUS_ENDPOINT_MISMATCH);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, writer, 0, &destination, 1,
                                  &read_result),
               OSVA_STATUS_ENDPOINT_MISMATCH);
  CHECK(FloatBits(destination) == 0);

  OSVAClientLease forged = writer;
  forged.client_id += 1;
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, forged),
               OSVA_STATUS_STALE_CLIENT_LEASE);
  forged = writer;
  forged.endpoint = OSVA_ENDPOINT_VISIBLE_INPUT;
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, forged),
               OSVA_STATUS_STALE_CLIENT_LEASE);
  forged = writer;
  forged.client_slot = UINT32_MAX;
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, forged),
               OSVA_STATUS_STALE_CLIENT_LEASE);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  CHECK_STATUS(
      OSVACoreWriteFrames(&fixture.core, writer, 0, &one, 1, &write_result),
      OSVA_STATUS_INACTIVE_CLIENT);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer),
               OSVA_STATUS_STALE_CLIENT_LEASE);

  OSVAClientLease replacement;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   12, &replacement),
               OSVA_STATUS_OK);
  CHECK(replacement.client_slot == writer.client_slot);
  CHECK(replacement.session_id != writer.session_id);
  CHECK(replacement.timeline_seed == writer.timeline_seed);
  CHECK_STATUS(
      OSVACoreWriteFrames(&fixture.core, writer, 0, &one, 1, &write_result),
      OSVA_STATUS_STALE_CLIENT_LEASE);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, replacement), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestOneThousandFreshEpochs(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 40, 0));
  uint64_t expected_session = 0;
  for (uint64_t restart = 0; restart < kRestartCount; ++restart) {
    const OSVAEndpoint first_endpoint = (restart & UINT64_C(1)) == 0
                                            ? OSVA_ENDPOINT_VISIBLE_INPUT
                                            : OSVA_ENDPOINT_HIDDEN_WRITER;
    const OSVAEndpoint second_endpoint =
        first_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT
            ? OSVA_ENDPOINT_HIDDEN_WRITER
            : OSVA_ENDPOINT_VISIBLE_INPUT;
    const uint64_t anchor = UINT64_C(1000000) + (restart * 17);
    const uint64_t expected_seed = UINT64_C(41) + restart;
    TestClockSet(&fixture.clock, anchor);
    OSVAClientLease first;
    OSVAClientLease second;
    CHECK_STATUS(OSVACoreStartClient(&fixture.core, first_endpoint,
                                     UINT64_C(10000) + restart, &first),
                 OSVA_STATUS_OK);
    expected_session += 1;
    CHECK(first.session_id == expected_session);
    CHECK(first.timeline_seed == expected_seed);
    CHECK(first.timeline_seed != 0);

    TestClockSet(&fixture.clock, anchor + 13);
    CHECK_STATUS(OSVACoreStartClient(&fixture.core, second_endpoint,
                                     UINT64_C(20000) + restart, &second),
                 OSVA_STATUS_OK);
    expected_session += 1;
    CHECK(second.session_id == expected_session);
    CHECK(second.timeline_seed == expected_seed);
    CHECK(CheckSnapshot(&fixture, true, (restart * 8) + 4, expected_seed,
                        anchor, 2, 1, 1));

    OSVAZeroTimestamp timestamp;
    CHECK_STATUS(
        OSVACoreGetZeroTimestampAtHostTicks(&fixture.core, anchor, &timestamp),
        OSVA_STATUS_OK);
    CHECK(timestamp.sample_frame == 0);
    CHECK(timestamp.host_ticks == anchor);
    CHECK(timestamp.seed == expected_seed);

    CHECK_STATUS(OSVACoreStopClient(&fixture.core, first), OSVA_STATUS_OK);
    CHECK(
        CheckSnapshot(&fixture, true, (restart * 8) + 6, expected_seed, anchor,
                      1, second_endpoint == OSVA_ENDPOINT_VISIBLE_INPUT ? 1 : 0,
                      second_endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 1 : 0));
    CHECK_STATUS(OSVACoreStopClient(&fixture.core, second), OSVA_STATUS_OK);
    CHECK(CheckSnapshot(&fixture, false, (restart + 1) * 8, 0, 0, 0, 0, 0));
  }
  CHECK(fixture.core.last_issued_seed == UINT64_C(1040));
  CHECK(fixture.core.last_issued_session_id == UINT64_C(2000));
  CHECK(TestClockCallCount(&fixture.clock) == kRestartCount);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestSeedAndSessionExhaustionAreTransactional(void) {
  TestFixture seed_fixture;
  CHECK(FixtureInitialize(&seed_fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, UINT64_MAX, 800));
  OSVACoreSnapshot before;
  CHECK_STATUS(OSVACoreGetSnapshot(&seed_fixture.core, &before),
               OSVA_STATUS_OK);
  OSVAClientLease rejected = {
      .client_id = 9,
      .session_id = 9,
      .timeline_seed = 9,
      .client_slot = 9,
      .endpoint = OSVA_ENDPOINT_VISIBLE_INPUT,
  };
  CHECK_STATUS(OSVACoreStartClient(&seed_fixture.core,
                                   OSVA_ENDPOINT_VISIBLE_INPUT, 1, &rejected),
               OSVA_STATUS_SEED_EXHAUSTED);
  CHECK(rejected.client_id == 0);
  CHECK(rejected.session_id == 0);
  CHECK(rejected.timeline_seed == 0);
  CHECK(rejected.client_slot == 0);
  CHECK(rejected.endpoint == 0);
  OSVACoreSnapshot after;
  CHECK_STATUS(OSVACoreGetSnapshot(&seed_fixture.core, &after), OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&before, &after));
  CHECK(seed_fixture.core.last_issued_seed == UINT64_MAX);
  CHECK(seed_fixture.core.last_issued_session_id == 0);
  CHECK(TestClockCallCount(&seed_fixture.clock) == 0);
  CHECK(FixtureDestroy(&seed_fixture));

  TestFixture session_fixture;
  CHECK(FixtureInitialize(&session_fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 3,
                          OSVA_SAMPLE_RATE_HZ, 17, 900));
  OSVAClientLease reader;
  CHECK_STATUS(OSVACoreStartClient(&session_fixture.core,
                                   OSVA_ENDPOINT_VISIBLE_INPUT, 2, &reader),
               OSVA_STATUS_OK);
  session_fixture.core.last_issued_session_id = UINT64_MAX;
  CHECK_STATUS(OSVACoreGetSnapshot(&session_fixture.core, &before),
               OSVA_STATUS_OK);
  const uint64_t clock_calls_before =
      TestClockCallCount(&session_fixture.clock);
  CHECK_STATUS(OSVACoreStartClient(&session_fixture.core,
                                   OSVA_ENDPOINT_HIDDEN_WRITER, 3, &rejected),
               OSVA_STATUS_SESSION_EXHAUSTED);
  CHECK_STATUS(OSVACoreGetSnapshot(&session_fixture.core, &after),
               OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&before, &after));
  CHECK(session_fixture.core.last_issued_seed == 18);
  CHECK(session_fixture.core.last_issued_session_id == UINT64_MAX);
  CHECK(TestClockCallCount(&session_fixture.clock) == clock_calls_before);
  CHECK_STATUS(OSVACoreStopClient(&session_fixture.core, reader),
               OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&session_fixture));

  TestFixture lifecycle_fixture;
  CHECK(FixtureInitialize(&lifecycle_fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 1,
                          OSVA_SAMPLE_RATE_HZ, 23, 1000));
  atomic_store_explicit(&lifecycle_fixture.core.lifecycle_sequence,
                        UINT64_MAX - 1, memory_order_release);
  CHECK_STATUS(OSVACoreGetSnapshot(&lifecycle_fixture.core, &before),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&lifecycle_fixture.core,
                                   OSVA_ENDPOINT_VISIBLE_INPUT, 4, &rejected),
               OSVA_STATUS_SESSION_EXHAUSTED);
  CHECK_STATUS(OSVACoreGetSnapshot(&lifecycle_fixture.core, &after),
               OSVA_STATUS_OK);
  CHECK(SnapshotEqual(&before, &after));
  CHECK(lifecycle_fixture.core.last_issued_seed == 23);
  CHECK(lifecycle_fixture.core.last_issued_session_id == 0);
  CHECK(TestClockCallCount(&lifecycle_fixture.clock) == 1);
  atomic_store_explicit(&lifecycle_fixture.core.lifecycle_sequence, 0,
                        memory_order_release);
  CHECK(FixtureDestroy(&lifecycle_fixture));
  return true;
}

static bool TestZeroTimestampBoundariesAndOverflow(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 100, 1000));
  OSVAClientLease reader;
  OSVAClientLease writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   1, &reader),
               OSVA_STATUS_OK);
  const uint64_t period = OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES;
  const struct {
    uint64_t observed;
    uint64_t sample;
    uint64_t host;
  } cases[] = {
      {1000, 0, 1000},
      {1000 + period - 1, 0, 1000},
      {1000 + period, period, 1000 + period},
      {1000 + (3 * period) + 123, 3 * period, 1000 + (3 * period)},
      {1000 + (97 * period) + (period - 1), 97 * period, 1000 + (97 * period)},
  };
  for (size_t index = 0; index < ARRAY_COUNT(cases); ++index) {
    OSVAZeroTimestamp timestamp;
    CHECK_STATUS(OSVACoreGetZeroTimestampAtHostTicks(
                     &fixture.core, cases[index].observed, &timestamp),
                 OSVA_STATUS_OK);
    CHECK(timestamp.sample_frame == cases[index].sample);
    CHECK(timestamp.host_ticks == cases[index].host);
    CHECK(timestamp.seed == 101);
  }

  OSVAZeroTimestamp regression = {
      .sample_frame = 9,
      .host_ticks = 9,
      .seed = 9,
  };
  CHECK_STATUS(
      OSVACoreGetZeroTimestampAtHostTicks(&fixture.core, 999, &regression),
      OSVA_STATUS_CLOCK_REGRESSION);
  CHECK(regression.sample_frame == 0);
  CHECK(regression.host_ticks == 0);
  CHECK(regression.seed == 0);

  TestClockSet(&fixture.clock, 1000 + (5 * period) + 1);
  OSVAZeroTimestamp clock_timestamp;
  CHECK_STATUS(OSVACoreGetZeroTimestamp(&fixture.core, &clock_timestamp),
               OSVA_STATUS_OK);
  CHECK(clock_timestamp.sample_frame == 5 * period);
  CHECK(clock_timestamp.host_ticks == 1000 + (5 * period));
  CHECK(clock_timestamp.seed == 101);

  TestClockSet(&fixture.clock, 9999);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   2, &writer),
               OSVA_STATUS_OK);
  OSVAZeroTimestamp shared_timestamp;
  CHECK_STATUS(OSVACoreGetZeroTimestampAtHostTicks(
                   &fixture.core, 1000 + (5 * period) + 1, &shared_timestamp),
               OSVA_STATUS_OK);
  CHECK(clock_timestamp.sample_frame == shared_timestamp.sample_frame);
  CHECK(clock_timestamp.host_ticks == shared_timestamp.host_ticks);
  CHECK(clock_timestamp.seed == shared_timestamp.seed);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));

  TestFixture fractional_fixture;
  const uint64_t nanoseconds_per_second = UINT64_C(1000000000);
  const uint64_t fractional_anchor = UINT64_C(5000000000);
  CHECK(FixtureInitialize(&fractional_fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 1,
                          nanoseconds_per_second, 0, fractional_anchor));
  CHECK_STATUS(OSVACoreStartClient(&fractional_fixture.core,
                                   OSVA_ENDPOINT_VISIBLE_INPUT, 3, &reader),
               OSVA_STATUS_OK);
  const uint64_t first_boundary_offset =
      (period * nanoseconds_per_second + OSVA_SAMPLE_RATE_HZ - 1) /
      OSVA_SAMPLE_RATE_HZ;
  OSVAZeroTimestamp fractional;
  CHECK_STATUS(OSVACoreGetZeroTimestampAtHostTicks(
                   &fractional_fixture.core,
                   fractional_anchor + first_boundary_offset - 1, &fractional),
               OSVA_STATUS_OK);
  CHECK(fractional.sample_frame == 0);
  CHECK(fractional.host_ticks == fractional_anchor);
  CHECK_STATUS(OSVACoreGetZeroTimestampAtHostTicks(
                   &fractional_fixture.core,
                   fractional_anchor + first_boundary_offset, &fractional),
               OSVA_STATUS_OK);
  CHECK(fractional.sample_frame == period);
  CHECK(fractional.host_ticks == fractional_anchor + first_boundary_offset);
  CHECK_STATUS(OSVACoreStopClient(&fractional_fixture.core, reader),
               OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fractional_fixture));

  TestFixture overflow_fixture;
  CHECK(FixtureInitialize(&overflow_fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 1,
                          1, 0, 0));
  CHECK_STATUS(OSVACoreStartClient(&overflow_fixture.core,
                                   OSVA_ENDPOINT_VISIBLE_INPUT, 4, &reader),
               OSVA_STATUS_OK);
  OSVAZeroTimestamp overflow = {
      .sample_frame = 9,
      .host_ticks = 9,
      .seed = 9,
  };
  CHECK_STATUS(OSVACoreGetZeroTimestampAtHostTicks(&overflow_fixture.core,
                                                   UINT64_MAX, &overflow),
               OSVA_STATUS_ARITHMETIC_OVERFLOW);
  CHECK(overflow.sample_frame == 0);
  CHECK(overflow.host_ticks == 0);
  CHECK(overflow.seed == 0);
  CHECK_STATUS(OSVACoreStopClient(&overflow_fixture.core, reader),
               OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&overflow_fixture));
  return true;
}

static bool TestInputFirstSilenceAndExactMonoBits(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 0, 1));
  OSVAClientLease reader;
  OSVAClientLease writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   101, &reader),
               OSVA_STATUS_OK);

  GuardedSamples destination;
  GuardedSamplesInitialize(&destination, UINT32_C(0x7FC00001));
  OSVAReadResult read_result;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 400,
                                  destination.samples, 16, &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.requested_frames == 16);
  CHECK(read_result.delivered_frames == 0);
  CHECK(read_result.underrun_frames == 16);
  CHECK(!read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == 0);
  CHECK(read_result.last_transferred_session_id == 0);
  CHECK(read_result.last_transferred_absolute_frame == 0);
  CHECK(SamplesArePositiveZero(destination.samples, 16));
  CHECK(GuardedSamplesCanariesAreIntact(&destination));

  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   102, &writer),
               OSVA_STATUS_OK);
  const uint32_t exact_bits[] = {
      UINT32_C(0x00000000), UINT32_C(0x80000000), UINT32_C(0x3F800000),
      UINT32_C(0xBF800000), UINT32_C(0x7F7FFFFF), UINT32_C(0xFF7FFFFF),
      UINT32_C(0x00800000), UINT32_C(0x80800000), UINT32_C(0x00000001),
      UINT32_C(0x80000001), UINT32_C(0x7FC12345), UINT32_C(0xFFC54321),
      UINT32_C(0x7F800000), UINT32_C(0xFF800000),
  };
  GuardedSamples source;
  GuardedSamplesInitialize(&source, 0);
  for (size_t index = 0; index < ARRAY_COUNT(exact_bits); ++index) {
    source.samples[index] = FloatFromBits(exact_bits[index]);
  }
  OSVAWriteResult write_result;
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, 400, source.samples,
                                   ARRAY_COUNT(exact_bits), &write_result),
               OSVA_STATUS_OK);
  CHECK(write_result.requested_frames == ARRAY_COUNT(exact_bits));
  CHECK(write_result.written_frames == ARRAY_COUNT(exact_bits));
  CHECK(write_result.contended_frames == 0);
  CHECK(write_result.has_last_transferred_frame);
  CHECK(write_result.last_transferred_timeline_seed == writer.timeline_seed);
  CHECK(write_result.last_transferred_session_id == writer.session_id);
  CHECK(write_result.last_transferred_absolute_frame ==
        UINT64_C(400) + ARRAY_COUNT(exact_bits) - 1);
  CHECK(GuardedSamplesCanariesAreIntact(&source));

  GuardedSamplesInitialize(&destination, UINT32_C(0xDEADBEEF));
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 400,
                                  destination.samples, ARRAY_COUNT(exact_bits),
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == ARRAY_COUNT(exact_bits));
  CHECK(read_result.underrun_frames == 0);
  CHECK(read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == writer.timeline_seed);
  CHECK(read_result.last_transferred_session_id == writer.session_id);
  CHECK(read_result.last_transferred_absolute_frame ==
        UINT64_C(400) + ARRAY_COUNT(exact_bits) - 1);
  CHECK(SamplesHaveBits(destination.samples, exact_bits,
                        ARRAY_COUNT(exact_bits)));
  CHECK(GuardedSamplesCanariesAreIntact(&destination));
  CHECK(FloatBits(source.samples[4]) == FloatBits(FLT_MAX));
  CHECK(FloatBits(source.samples[6]) == FloatBits(FLT_MIN));

  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestWriterFirstWrapOverlapFutureAndLate(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 4, 10));
  OSVAClientLease writer;
  OSVAClientLease reader;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   201, &writer),
               OSVA_STATUS_OK);
  const size_t capacity = fixture.ring_capacity_frames;
  const uint32_t first_bits[] = {
      UINT32_C(0x3D000001), UINT32_C(0x3D000002), UINT32_C(0x3D000003),
      UINT32_C(0x3D000004), UINT32_C(0x3D000005),
  };
  float first[ARRAY_COUNT(first_bits)];
  for (size_t index = 0; index < ARRAY_COUNT(first_bits); ++index) {
    first[index] = FloatFromBits(first_bits[index]);
  }
  OSVAWriteResult write_result;
  const uint64_t wrap_start = (uint64_t)capacity - 2;
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, wrap_start, first,
                                   ARRAY_COUNT(first), &write_result),
               OSVA_STATUS_OK);
  CHECK(write_result.written_frames == ARRAY_COUNT(first));

  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   202, &reader),
               OSVA_STATUS_OK);
  float destination[ARRAY_COUNT(first)];
  OSVAReadResult read_result;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, wrap_start,
                                  destination, ARRAY_COUNT(destination),
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == ARRAY_COUNT(destination));
  CHECK(SamplesHaveBits(destination, first_bits, ARRAY_COUNT(first_bits)));

  const uint32_t replacement_bits[] = {
      UINT32_C(0x3E000011),
      UINT32_C(0x3E000012),
      UINT32_C(0x3E000013),
  };
  float replacement[ARRAY_COUNT(replacement_bits)];
  for (size_t index = 0; index < ARRAY_COUNT(replacement_bits); ++index) {
    replacement[index] = FloatFromBits(replacement_bits[index]);
  }
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, wrap_start + 1,
                                   replacement, ARRAY_COUNT(replacement),
                                   &write_result),
               OSVA_STATUS_OK);
  const uint32_t overlap_expected[] = {
      UINT32_C(0x3D000001), UINT32_C(0x3E000011), UINT32_C(0x3E000012),
      UINT32_C(0x3E000013), UINT32_C(0x3D000005),
  };
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, wrap_start,
                                  destination, ARRAY_COUNT(destination),
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(SamplesHaveBits(destination, overlap_expected,
                        ARRAY_COUNT(overlap_expected)));

  const uint64_t aliased_frame = (uint64_t)capacity + 77;
  const float aliased_value = FloatFromBits(UINT32_C(0x3F123456));
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, aliased_frame,
                                   &aliased_value, 1, &write_result),
               OSVA_STATUS_OK);
  float one = 9.0F;
  CHECK_STATUS(
      OSVACoreReadFrames(&fixture.core, reader, 77, &one, 1, &read_result),
      OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(FloatBits(one) == 0);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, aliased_frame, &one, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 1);
  CHECK(FloatBits(one) == UINT32_C(0x3F123456));

  const uint64_t future_frame = aliased_frame + (uint64_t)capacity;
  one = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, future_frame, &one, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(FloatBits(one) == 0);
  const float future_value = FloatFromBits(UINT32_C(0xBF654321));
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, future_frame,
                                   &future_value, 1, &write_result),
               OSVA_STATUS_OK);
  one = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, aliased_frame, &one, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(FloatBits(one) == 0);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, future_frame, &one, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(FloatBits(one) == UINT32_C(0xBF654321));

  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestStaleDataAcrossWriterAndFullRestarts(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 0, 100));
  OSVAClientLease reader;
  OSVAClientLease writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   301, &reader),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   302, &writer),
               OSVA_STATUS_OK);
  const float old_value = FloatFromBits(UINT32_C(0x3F010203));
  OSVAWriteResult write_result;
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, 900, &old_value, 1,
                                   &write_result),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  float destination = 9.0F;
  OSVAReadResult read_result;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 900, &destination, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(FloatBits(destination) == 0);

  OSVAClientLease restarted_writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   302, &restarted_writer),
               OSVA_STATUS_OK);
  CHECK(restarted_writer.timeline_seed == reader.timeline_seed);
  CHECK(restarted_writer.session_id != writer.session_id);
  destination = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 900, &destination, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  const float new_value = FloatFromBits(UINT32_C(0xBF112233));
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, restarted_writer, 900,
                                   &new_value, 1, &write_result),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 900, &destination, 1,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(FloatBits(destination) == UINT32_C(0xBF112233));

  const uint64_t old_seed = reader.timeline_seed;
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, restarted_writer),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  TestClockSet(&fixture.clock, 200);
  OSVAClientLease new_reader;
  OSVAClientLease new_writer;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   301, &new_reader),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   302, &new_writer),
               OSVA_STATUS_OK);
  CHECK(new_reader.timeline_seed == old_seed + 1);
  destination = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, new_reader, 900, &destination,
                                  1, &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(FloatBits(destination) == 0);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, new_writer), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, new_reader), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

static bool TestFrameOverflowContentionAndBufferCanaries(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 0, 123));
  OSVAClientLease writer;
  OSVAClientLease reader;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   401, &writer),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   402, &reader),
               OSVA_STATUS_OK);
  GuardedSamples source;
  GuardedSamples destination;
  GuardedSamplesInitialize(&source, UINT32_C(0x3F765432));
  GuardedSamplesInitialize(&destination, UINT32_C(0x7FC00001));
  OSVAWriteResult write_result = {
      .requested_frames = 77,
      .written_frames = 77,
      .contended_frames = 77,
  };
  OSVAReadResult read_result = {
      .requested_frames = 88,
      .delivered_frames = 88,
      .underrun_frames = 88,
  };
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, UINT64_MAX,
                                   source.samples, 2, &write_result),
               OSVA_STATUS_INVALID_ARGUMENT);
  CHECK(write_result.requested_frames == 77);
  CHECK(write_result.written_frames == 77);
  CHECK(write_result.contended_frames == 77);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, UINT64_MAX,
                                  destination.samples, 2, &read_result),
               OSVA_STATUS_INVALID_ARGUMENT);
  CHECK(read_result.requested_frames == 88);
  CHECK(read_result.delivered_frames == 88);
  CHECK(read_result.underrun_frames == 88);
  CHECK(FloatBits(destination.samples[0]) == UINT32_C(0x7FC00001));
  CHECK(GuardedSamplesCanariesAreIntact(&source));
  CHECK(GuardedSamplesCanariesAreIntact(&destination));

  const size_t oversized_frame_count =
      (SIZE_MAX / sizeof(source.samples[0])) + 1;
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, 0, source.samples,
                                   oversized_frame_count, &write_result),
               OSVA_STATUS_INVALID_ARGUMENT);
  CHECK(write_result.requested_frames == 77);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 0, destination.samples,
                                  oversized_frame_count, &read_result),
               OSVA_STATUS_INVALID_ARGUMENT);
  CHECK(read_result.requested_frames == 88);
  CHECK(FloatBits(destination.samples[0]) == UINT32_C(0x7FC00001));

  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, UINT64_MAX - 1,
                                   source.samples, 2, &write_result),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, UINT64_MAX - 1,
                                  destination.samples, 2, &read_result),
               OSVA_STATUS_OK);
  const uint32_t expected_pair[] = {
      UINT32_C(0x3F765432),
      UINT32_C(0x3F765432),
  };
  CHECK(SamplesHaveBits(destination.samples, expected_pair, 2));

  const uint64_t contended_frame = 71;
  OSVARingSlot *contended_slot =
      &fixture.ring_slots[contended_frame & fixture.core.ring_index_mask];
  atomic_store_explicit(&contended_slot->sequence, 1, memory_order_release);
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, contended_frame,
                                   source.samples, 1, &write_result),
               OSVA_STATUS_OK);
  CHECK(write_result.written_frames == 0);
  CHECK(write_result.contended_frames == 1);
  CHECK(!write_result.has_last_transferred_frame);
  CHECK(write_result.last_transferred_timeline_seed == 0);
  CHECK(write_result.last_transferred_session_id == 0);
  CHECK(write_result.last_transferred_absolute_frame == 0);
  destination.samples[0] = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, contended_frame,
                                  destination.samples, 1, &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(!read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == 0);
  CHECK(read_result.last_transferred_session_id == 0);
  CHECK(read_result.last_transferred_absolute_frame == 0);
  CHECK(FloatBits(destination.samples[0]) == 0);

  atomic_store_explicit(&contended_slot->sequence, UINT64_MAX - 1,
                        memory_order_release);
  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, contended_frame,
                                   source.samples, 1, &write_result),
               OSVA_STATUS_OK);
  CHECK(write_result.written_frames == 0);
  CHECK(write_result.contended_frames == 1);
  CHECK(!write_result.has_last_transferred_frame);
  CHECK(write_result.last_transferred_timeline_seed == 0);
  CHECK(write_result.last_transferred_session_id == 0);
  CHECK(write_result.last_transferred_absolute_frame == 0);
  CHECK(atomic_load_explicit(&contended_slot->sequence, memory_order_acquire) ==
        UINT64_MAX - 1);
  destination.samples[0] = 9.0F;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, contended_frame,
                                  destination.samples, 1, &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == 0);
  CHECK(!read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == 0);
  CHECK(read_result.last_transferred_session_id == 0);
  CHECK(read_result.last_transferred_absolute_frame == 0);
  CHECK(FloatBits(destination.samples[0]) == 0);

  CHECK_STATUS(OSVACoreWriteFrames(&fixture.core, writer, UINT64_MAX, NULL, 0,
                                   &write_result),
               OSVA_STATUS_OK);
  CHECK(write_result.requested_frames == 0);
  CHECK(!write_result.has_last_transferred_frame);
  CHECK(write_result.last_transferred_timeline_seed == 0);
  CHECK(write_result.last_transferred_session_id == 0);
  CHECK(write_result.last_transferred_absolute_frame == 0);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, UINT64_MAX, NULL, 0,
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.requested_frames == 0);
  CHECK(!read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == 0);
  CHECK(read_result.last_transferred_session_id == 0);
  CHECK(read_result.last_transferred_absolute_frame == 0);

  read_result = (OSVAReadResult){
      .requested_frames = 99,
      .delivered_frames = 99,
      .underrun_frames = 99,
      .has_last_transferred_frame = true,
      .last_transferred_timeline_seed = 99,
      .last_transferred_session_id = 99,
      .last_transferred_absolute_frame = 99,
  };
  destination.samples[0] = 9.0F;
  const uint64_t stable_lifecycle_sequence = atomic_load_explicit(
      &fixture.core.lifecycle_sequence, memory_order_acquire);
  CHECK((stable_lifecycle_sequence & UINT64_C(1)) == 0);
  atomic_store_explicit(&fixture.core.lifecycle_sequence,
                        stable_lifecycle_sequence + 1, memory_order_release);
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader, 0,
                                  destination.samples, 1, &read_result),
               OSVA_STATUS_RETRY);
  atomic_store_explicit(&fixture.core.lifecycle_sequence,
                        stable_lifecycle_sequence, memory_order_release);
  CHECK(read_result.requested_frames == 1);
  CHECK(read_result.delivered_frames == 0);
  CHECK(read_result.underrun_frames == 1);
  CHECK(!read_result.has_last_transferred_frame);
  CHECK(read_result.last_transferred_timeline_seed == 0);
  CHECK(read_result.last_transferred_session_id == 0);
  CHECK(read_result.last_transferred_absolute_frame == 0);
  CHECK(FloatBits(destination.samples[0]) == 0);
  CHECK(GuardedSamplesCanariesAreIntact(&source));
  CHECK(GuardedSamplesCanariesAreIntact(&destination));
  CHECK(FixtureStorageIsIntact(&fixture));
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

typedef struct ConcurrentIOContext {
  OSVACore *core;
  OSVAClientLease lease;
  _Atomic bool *start;
  _Atomic unsigned *failure_count;
  uint32_t sample_bits;
  unsigned iterations;
} ConcurrentIOContext;

static void RecordConcurrentFailure(_Atomic unsigned *failure_count) {
  (void)atomic_fetch_add_explicit(failure_count, 1, memory_order_relaxed);
}

static void AwaitConcurrentStart(const _Atomic bool *start) {
  while (!atomic_load_explicit(start, memory_order_acquire)) {
    sched_yield();
  }
}

static void *ConcurrentWriterMain(void *opaque_context) {
  ConcurrentIOContext *context = opaque_context;
  float samples[kConcurrentFrameCount];
  for (size_t index = 0; index < ARRAY_COUNT(samples); ++index) {
    samples[index] = FloatFromBits(context->sample_bits);
  }
  AwaitConcurrentStart(context->start);
  for (unsigned iteration = 0; iteration < context->iterations; ++iteration) {
    OSVAWriteResult result;
    const OSVAStatus status =
        OSVACoreWriteFrames(context->core, context->lease, 4096, samples,
                            ARRAY_COUNT(samples), &result);
    if (status != OSVA_STATUS_OK ||
        result.requested_frames != ARRAY_COUNT(samples) ||
        result.written_frames + result.contended_frames !=
            ARRAY_COUNT(samples)) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
  }
  return NULL;
}

typedef struct ConcurrentReaderContext {
  OSVACore *core;
  OSVAClientLease lease;
  _Atomic bool *start;
  _Atomic unsigned *failure_count;
  uint32_t first_valid_bits;
  uint32_t second_valid_bits;
  unsigned iterations;
} ConcurrentReaderContext;

static void *ConcurrentReaderMain(void *opaque_context) {
  ConcurrentReaderContext *context = opaque_context;
  float samples[kConcurrentFrameCount];
  AwaitConcurrentStart(context->start);
  for (unsigned iteration = 0; iteration < context->iterations; ++iteration) {
    memset(samples, 0xA5, sizeof(samples));
    OSVAReadResult result;
    const OSVAStatus status =
        OSVACoreReadFrames(context->core, context->lease, 4096, samples,
                           ARRAY_COUNT(samples), &result);
    if (status != OSVA_STATUS_OK ||
        result.delivered_frames + result.underrun_frames !=
            ARRAY_COUNT(samples)) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
    for (size_t index = 0; index < ARRAY_COUNT(samples); ++index) {
      const uint32_t bits = FloatBits(samples[index]);
      if (bits != 0 && bits != context->first_valid_bits &&
          bits != context->second_valid_bits) {
        RecordConcurrentFailure(context->failure_count);
        return NULL;
      }
    }
  }
  return NULL;
}

static bool TestConcurrentReadersAndWriters(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 4,
                          OSVA_SAMPLE_RATE_HZ, 0, 1000));
  OSVAClientLease reader_one;
  OSVAClientLease reader_two;
  OSVAClientLease writer_one;
  OSVAClientLease writer_two;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   501, &reader_one),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   502, &reader_two),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   503, &writer_one),
               OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_HIDDEN_WRITER,
                                   504, &writer_two),
               OSVA_STATUS_OK);

  _Atomic bool start;
  _Atomic unsigned failure_count;
  atomic_init(&start, false);
  atomic_init(&failure_count, 0);
  const uint32_t first_bits = UINT32_C(0x3E112233);
  const uint32_t second_bits = UINT32_C(0xBE445566);
  ConcurrentIOContext writer_contexts[] = {
      {&fixture.core, writer_one, &start, &failure_count, first_bits,
       kConcurrentWriterIterations},
      {&fixture.core, writer_two, &start, &failure_count, second_bits,
       kConcurrentWriterIterations},
  };
  ConcurrentReaderContext reader_contexts[] = {
      {&fixture.core, reader_one, &start, &failure_count, first_bits,
       second_bits, kConcurrentReaderIterations},
      {&fixture.core, reader_two, &start, &failure_count, first_bits,
       second_bits, kConcurrentReaderIterations},
  };
  pthread_t writer_threads[ARRAY_COUNT(writer_contexts)];
  pthread_t reader_threads[ARRAY_COUNT(reader_contexts)];
  for (size_t index = 0; index < ARRAY_COUNT(writer_contexts); ++index) {
    CHECK(pthread_create(&writer_threads[index], NULL, ConcurrentWriterMain,
                         &writer_contexts[index]) == 0);
  }
  for (size_t index = 0; index < ARRAY_COUNT(reader_contexts); ++index) {
    CHECK(pthread_create(&reader_threads[index], NULL, ConcurrentReaderMain,
                         &reader_contexts[index]) == 0);
  }
  atomic_store_explicit(&start, true, memory_order_release);
  for (size_t index = 0; index < ARRAY_COUNT(writer_threads); ++index) {
    CHECK(pthread_join(writer_threads[index], NULL) == 0);
  }
  for (size_t index = 0; index < ARRAY_COUNT(reader_threads); ++index) {
    CHECK(pthread_join(reader_threads[index], NULL) == 0);
  }
  CHECK(atomic_load_explicit(&failure_count, memory_order_relaxed) == 0);

  float final_samples[kConcurrentFrameCount];
  OSVAReadResult read_result;
  CHECK_STATUS(OSVACoreReadFrames(&fixture.core, reader_one, 4096,
                                  final_samples, ARRAY_COUNT(final_samples),
                                  &read_result),
               OSVA_STATUS_OK);
  CHECK(read_result.delivered_frames == ARRAY_COUNT(final_samples));
  for (size_t index = 0; index < ARRAY_COUNT(final_samples); ++index) {
    const uint32_t bits = FloatBits(final_samples[index]);
    CHECK(bits == first_bits || bits == second_bits);
  }
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer_two), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, writer_one), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader_two), OSVA_STATUS_OK);
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader_one), OSVA_STATUS_OK);
  CHECK(FixtureDestroy(&fixture));
  return true;
}

typedef struct LifecycleStressContext {
  OSVACore *core;
  OSVAClientLease reader;
  _Atomic bool *start;
  _Atomic unsigned *failure_count;
  uint64_t anchor;
  uint64_t seed;
} LifecycleStressContext;

static void *LifecycleWriterMain(void *opaque_context) {
  LifecycleStressContext *context = opaque_context;
  float samples[32];
  for (size_t index = 0; index < ARRAY_COUNT(samples); ++index) {
    samples[index] = FloatFromBits(UINT32_C(0x3F334455));
  }
  AwaitConcurrentStart(context->start);
  for (uint64_t iteration = 0; iteration < kLifecycleIterations; ++iteration) {
    OSVAClientLease writer;
    OSVAStatus status = OSVACoreStartClient(
        context->core, OSVA_ENDPOINT_HIDDEN_WRITER, UINT64_C(7000), &writer);
    if (status != OSVA_STATUS_OK || writer.timeline_seed != context->seed) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
    OSVAWriteResult result;
    status = OSVACoreWriteFrames(context->core, writer, 700, samples,
                                 ARRAY_COUNT(samples), &result);
    if (status != OSVA_STATUS_OK ||
        result.written_frames + result.contended_frames !=
            ARRAY_COUNT(samples)) {
      RecordConcurrentFailure(context->failure_count);
      (void)OSVACoreStopClient(context->core, writer);
      break;
    }
    if (OSVACoreStopClient(context->core, writer) != OSVA_STATUS_OK) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
  }
  return NULL;
}

static void *LifecycleReaderMain(void *opaque_context) {
  LifecycleStressContext *context = opaque_context;
  float samples[32];
  AwaitConcurrentStart(context->start);
  for (unsigned iteration = 0; iteration < kConcurrentReaderIterations;
       ++iteration) {
    OSVAReadResult result;
    const OSVAStatus status =
        OSVACoreReadFrames(context->core, context->reader, 700, samples,
                           ARRAY_COUNT(samples), &result);
    if (status != OSVA_STATUS_OK && status != OSVA_STATUS_RETRY) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
    if (status == OSVA_STATUS_RETRY &&
        (result.delivered_frames != 0 ||
         result.underrun_frames != ARRAY_COUNT(samples) ||
         result.has_last_transferred_frame ||
         result.last_transferred_timeline_seed != 0 ||
         result.last_transferred_session_id != 0 ||
         result.last_transferred_absolute_frame != 0 ||
         !SamplesArePositiveZero(samples, ARRAY_COUNT(samples)))) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
    if (result.delivered_frames + result.underrun_frames !=
        ARRAY_COUNT(samples)) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
    for (size_t index = 0; index < ARRAY_COUNT(samples); ++index) {
      const uint32_t bits = FloatBits(samples[index]);
      if (bits != 0 && bits != UINT32_C(0x3F334455)) {
        RecordConcurrentFailure(context->failure_count);
        return NULL;
      }
    }
  }
  return NULL;
}

static void *LifecycleTimestampMain(void *opaque_context) {
  LifecycleStressContext *context = opaque_context;
  AwaitConcurrentStart(context->start);
  for (unsigned iteration = 0; iteration < kConcurrentReaderIterations;
       ++iteration) {
    OSVAZeroTimestamp timestamp;
    const OSVAStatus status = OSVACoreGetZeroTimestampAtHostTicks(
        context->core,
        context->anchor + (2 * OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES) + 7,
        &timestamp);
    if (status == OSVA_STATUS_RETRY) {
      continue;
    }
    if (status != OSVA_STATUS_OK ||
        timestamp.sample_frame != 2 * OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES ||
        timestamp.host_ticks !=
            context->anchor + (2 * OSVA_ZERO_TIMESTAMP_PERIOD_FRAMES) ||
        timestamp.seed != context->seed) {
      RecordConcurrentFailure(context->failure_count);
      break;
    }
  }
  return NULL;
}

static bool TestConcurrentLifecycleAndTimelineStress(void) {
  TestFixture fixture;
  CHECK(FixtureInitialize(&fixture, OSVA_MIN_RING_CAPACITY_FRAMES, 2,
                          OSVA_SAMPLE_RATE_HZ, 70, 3000));
  OSVAClientLease reader;
  CHECK_STATUS(OSVACoreStartClient(&fixture.core, OSVA_ENDPOINT_VISIBLE_INPUT,
                                   601, &reader),
               OSVA_STATUS_OK);
  _Atomic bool start;
  _Atomic unsigned failure_count;
  atomic_init(&start, false);
  atomic_init(&failure_count, 0);
  LifecycleStressContext context = {
      .core = &fixture.core,
      .reader = reader,
      .start = &start,
      .failure_count = &failure_count,
      .anchor = 3000,
      .seed = 71,
  };
  pthread_t writer_thread;
  pthread_t reader_thread;
  pthread_t timestamp_thread;
  CHECK(pthread_create(&writer_thread, NULL, LifecycleWriterMain, &context) ==
        0);
  CHECK(pthread_create(&reader_thread, NULL, LifecycleReaderMain, &context) ==
        0);
  CHECK(pthread_create(&timestamp_thread, NULL, LifecycleTimestampMain,
                       &context) == 0);
  atomic_store_explicit(&start, true, memory_order_release);
  CHECK(pthread_join(writer_thread, NULL) == 0);
  CHECK(pthread_join(reader_thread, NULL) == 0);
  CHECK(pthread_join(timestamp_thread, NULL) == 0);
  CHECK(atomic_load_explicit(&failure_count, memory_order_relaxed) == 0);
  CHECK(CheckSnapshot(&fixture, true, 2 + (4 * kLifecycleIterations), 71, 3000,
                      1, 1, 0));
  CHECK_STATUS(OSVACoreStopClient(&fixture.core, reader), OSVA_STATUS_OK);
  CHECK(CheckSnapshot(&fixture, false, 4 + (4 * kLifecycleIterations), 0, 0, 0,
                      0, 0));
  CHECK(FixtureDestroy(&fixture));
  return true;
}

int main(void) {
  const struct {
    const char *name;
    bool (*run)(void);
  } tests[] = {
      {"constants, initialization, and status names",
       TestConstantsInitializationAndStatusNames},
      {"visible-first/writer-first joins and leaves",
       TestVisibleFirstWriterFirstJoinsAndLeaves},
      {"lease rejection and capacity", TestLeaseRejectionAndCapacity},
      {"1000 fresh epochs", TestOneThousandFreshEpochs},
      {"seed/session exhaustion is transactional",
       TestSeedAndSessionExhaustionAreTransactional},
      {"zero timestamp boundaries and overflow",
       TestZeroTimestampBoundariesAndOverflow},
      {"input-first silence and exact mono bits",
       TestInputFirstSilenceAndExactMonoBits},
      {"writer-first wrap/overlap/future/late",
       TestWriterFirstWrapOverlapFutureAndLate},
      {"stale data across writer/full restarts",
       TestStaleDataAcrossWriterAndFullRestarts},
      {"frame overflow, contention, and canaries",
       TestFrameOverflowContentionAndBufferCanaries},
      {"concurrent readers and writers", TestConcurrentReadersAndWriters},
      {"concurrent lifecycle and timeline stress",
       TestConcurrentLifecycleAndTimelineStress},
  };
  size_t passed = 0;
  for (size_t index = 0; index < ARRAY_COUNT(tests); ++index) {
    if (!tests[index].run()) {
      fprintf(stderr, "FAILED: %s\n", tests[index].name);
      return 1;
    }
    printf("PASS: %s\n", tests[index].name);
    passed += 1;
  }
  printf("PASS: %zu/%zu production core invariant tests\n", passed,
         ARRAY_COUNT(tests));
  return 0;
}
