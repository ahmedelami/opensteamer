#ifndef OPENSTEAMER_VIRTUAL_MICROPHONE_DRIVER_H
#define OPENSTEAMER_VIRTUAL_MICROPHONE_DRIVER_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  kOSVAObjectIDPlugIn = kAudioObjectPlugInObject,
  kOSVAObjectIDVisibleInputDevice = 2,
  kOSVAObjectIDVisibleInputStream = 3,
  kOSVAObjectIDVisibleInputVolume = 4,
  kOSVAObjectIDVisibleInputMute = 5,
  kOSVAObjectIDHiddenWriterDevice = 6,
  kOSVAObjectIDHiddenWriterStream = 7,
  kOSVAObjectIDHiddenWriterVolume = 8,
  kOSVAObjectIDHiddenWriterMute = 9,
};

#define OSVA_BUNDLE_IDENTIFIER "com.elamin.opensteamer.VirtualMicrophoneDriver"
#define OSVA_VISIBLE_INPUT_DEVICE_UID                                          \
  "com.elamin.opensteamer.virtual-microphone.input"
#define OSVA_HIDDEN_WRITER_DEVICE_UID                                          \
  "com.elamin.opensteamer.virtual-microphone.writer"
#define OSVA_DEVICE_MODEL_UID "com.elamin.opensteamer.virtual-microphone.model"
#define kOSVADiagnosticSnapshotUnavailableError kAudioHardwareUnspecifiedError

enum {
  kOSVAClockDomain = 0x6F73564D,
  kOSVAZeroTimeStampPeriodFrames = 16384,
  kOSVARingCapacityFrames = 131072,
  kOSVADiagnosticSnapshotSchemaVersion = 1,
  kOSVADiagnosticClientSlotCapacity = 64,
  kOSVADiagnosticSnapshotByteCount = 8608,
  /*
   * FourCC "osDS". Global/main, read-only, and available on both devices.
   * The marshalled property is a CFPropertyListRef whose concrete value is
   * CFData containing exactly one OSVADiagnosticSnapshot.
   */
  kOSVADiagnosticSnapshotProperty = 0x6F734453,
};

enum {
  kOSVADiagnosticEndpointNone = 0,
  kOSVADiagnosticEndpointVisibleInput = 1,
  kOSVADiagnosticEndpointHiddenWriter = 2,
};

enum {
  kOSVADiagnosticDriverSlotRegistered = 1U << 0,
  kOSVADiagnosticDriverSlotStarted = 1U << 1,
  kOSVADiagnosticDriverSlotLeaseValid = 1U << 2,
};

enum {
  /* At least one complete observation has been published into this record. */
  kOSVADiagnosticRecordPresent = 1U << 0,
  /* The retained last-success tuple is populated and internally coherent. */
  kOSVADiagnosticRecordLastSuccessTupleValid = 1U << 1,
  /* The most recently observed call/cycle itself was valid. */
  kOSVADiagnosticRecordLastCallValid = 1U << 2,
  /* The retained successful zero-timestamp tuple came from the cache. */
  kOSVADiagnosticRecordUsedFallback = 1U << 3,
  /* The retained success tuple includes its coherent seed generation. */
  kOSVADiagnosticRecordEpochMappingValid = 1U << 4,
};

enum {
  kOSVADiagnosticSnapshotCoreInitialized = UINT64_C(1) << 0,
  kOSVADiagnosticSnapshotTimelineActive = UINT64_C(1) << 1,
  kOSVADiagnosticInvariantGlobalMatchesCoreSlots = UINT64_C(1) << 8,
  kOSVADiagnosticInvariantEndpointsMatchCoreSlots = UINT64_C(1) << 9,
  kOSVADiagnosticInvariantDriverStartsMatchCoreSlots = UINT64_C(1) << 10,
  kOSVADiagnosticInvariantIdleImpliesClockCleared = UINT64_C(1) << 11,
  kOSVADiagnosticInvariantActiveImpliesClockValid = UINT64_C(1) << 12,
  kOSVADiagnosticInvariantSlotCountsWithinCapacity = UINT64_C(1) << 13,
  kOSVADiagnosticInvariantStartStopBalancedAtIdle = UINT64_C(1) << 14,
  kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle = UINT64_C(1) << 15,
  kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed =
      UINT64_C(1) << 16,
  kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration =
      UINT64_C(1) << 17,
};

typedef enum OSVADiagnosticTransitionType {
  kOSVADiagnosticTransitionNone = 0,
  kOSVADiagnosticTransitionDriverClientAdded = 1,
  kOSVADiagnosticTransitionDriverClientRemoved = 2,
  kOSVADiagnosticTransitionIOStarted = 3,
  kOSVADiagnosticTransitionIOStopped = 4,
  kOSVADiagnosticTransitionSeedCreated = 5,
  kOSVADiagnosticTransitionSeedCleared = 6,
} OSVADiagnosticTransitionType;

typedef struct OSVADiagnosticTransitionSnapshot {
  UInt64 host_ticks;
  UInt64 client_id;
  UInt64 pre_global_active_count;
  UInt64 post_global_active_count;
  UInt64 driver_client_generation;
  UInt64 core_session_id;
  UInt64 reserved;
  UInt32 type;
  UInt32 endpoint_role;
  UInt32 slot_index;
  SInt32 process_id;
} OSVADiagnosticTransitionSnapshot;

typedef struct OSVADiagnosticDriverClientSlotSnapshot {
  UInt64 generation;
  UInt64 registration_host_ticks;
  UInt64 start_host_ticks;
  UInt64 last_transition_host_ticks;
  UInt64 lease_session_id;
  UInt64 lease_timeline_seed;
  UInt32 flags;
  UInt32 device_object_id;
  UInt32 client_id;
  SInt32 process_id;
  UInt32 endpoint_role;
  UInt32 core_client_slot;
  UInt32 io_start_depth;
  UInt32 reserved;
} OSVADiagnosticDriverClientSlotSnapshot;

typedef struct OSVADiagnosticCoreClientSlotSnapshot {
  UInt64 session_id;
  UInt64 client_id;
  UInt64 timeline_seed;
  UInt32 endpoint_role;
  UInt32 reserved;
} OSVADiagnosticCoreClientSlotSnapshot;

typedef struct OSVADiagnosticZeroTimestampSnapshot {
  /* Exact event generation; advances for every HAL callback. */
  UInt64 sequence;
  UInt64 metadata_sequence;
  /* Optional last-call/tuple updates rejected due to writer contention. */
  UInt64 metadata_dropped_update_count;
  /* Must remain zero in v1: the nonzero timeline seed is the generation. */
  UInt64 epoch_mapping_unavailable_count;
  UInt64 call_count;
  UInt64 successful_return_count;
  UInt64 fallback_return_count;
  UInt64 failed_return_count;
  UInt64 last_call_host_ticks;
  UInt64 last_sample_frame;
  UInt64 last_host_ticks;
  UInt64 last_seed;
  UInt64 last_seed_generation;
  /* Lifecycle sequence belonging to the retained successful tuple. */
  UInt64 last_core_lifecycle_sequence;
  /* Lifecycle sequence observed for the most recent call, including failure. */
  UInt64 last_call_core_lifecycle_sequence;
  UInt32 last_client_id;
  SInt32 last_status;
  UInt32 flags;
  UInt32 reserved;
} OSVADiagnosticZeroTimestampSnapshot;

typedef struct OSVADiagnosticIOSnapshot {
  /* Exact event generation; advances for every I/O callback. */
  UInt64 sequence;
  UInt64 metadata_sequence;
  /* Optional last-cycle/tuple updates rejected due to writer contention. */
  UInt64 metadata_dropped_update_count;
  UInt64 operation_call_count;
  UInt64 valid_cycle_count;
  UInt64 invalid_cycle_count;
  UInt64 lease_unavailable_count;
  /* Must remain zero in v1: the nonzero timeline seed is the generation. */
  UInt64 epoch_mapping_unavailable_count;
  UInt64 core_ok_count;
  UInt64 core_retry_count;
  UInt64 core_failure_count;
  UInt64 requested_frame_count;
  UInt64 transferred_frame_count;
  UInt64 gap_frame_count;
  UInt64 last_cycle_sample_frame;
  UInt64 last_cycle_host_ticks;
  UInt64 last_published_frame_seed;
  UInt64 last_published_seed_generation;
  UInt64 last_published_frame_session;
  UInt64 last_published_absolute_frame;
  UInt64 last_consumed_frame_seed;
  UInt64 last_consumed_seed_generation;
  UInt64 last_consumed_frame_session;
  UInt64 last_consumed_absolute_frame;
  UInt32 last_client_id;
  SInt32 last_status;
  UInt32 flags;
  UInt32 reserved;
} OSVADiagnosticIOSnapshot;

typedef struct OSVADiagnosticIOWorkLoopSnapshot {
  /* Exact event generation; advances for every successful callback. */
  UInt64 sequence;
  UInt64 metadata_sequence;
  /*
   * Bounded current-count or last-transition updates rejected due to
   * contention. Nonzero means current_count may be conservative; the exact
   * begin/end totals remain authoritative.
   */
  UInt64 metadata_dropped_update_count;
  UInt64 current_count;
  UInt64 begin_count;
  UInt64 end_count;
  UInt64 underflow_count;
  UInt64 last_transition_host_ticks;
  UInt32 last_client_id;
  UInt32 flags;
} OSVADiagnosticIOWorkLoopSnapshot;

/*
 * Fixed-size, versioned, process-independent POD carried verbatim inside the
 * CFData returned by kOSVADiagnosticSnapshotProperty. Readers must validate
 * the CFData type and exact length, then both leading fields.
 */
typedef struct OSVADiagnosticSnapshot {
  UInt32 schema_version;
  UInt32 struct_size;
  UInt64 snapshot_sequence;
  UInt64 captured_host_ticks;
  UInt64 driver_instance_generation;
  UInt64 invariant_flags;
  UInt64 driver_lifecycle_sequence;
  UInt64 core_lifecycle_sequence;
  UInt64 host_ticks_per_second;

  UInt64 timeline_seed;
  /*
   * The core's nonzero monotonic timeline seed is the epoch generation within
   * one driver instance. Pair it with driver_instance_generation across
   * coreaudiod/driver reloads.
   */
  UInt64 current_seed_generation;
  UInt64 anchor_host_ticks;
  UInt64 last_issued_seed;
  UInt64 last_issued_session_id;
  UInt64 active_client_count;
  UInt64 visible_input_active_count;
  UInt64 hidden_writer_active_count;
  UInt64 core_active_slot_count;
  UInt64 core_active_slot_bitmap;

  UInt64 driver_registered_count;
  UInt64 driver_started_count;
  UInt64 visible_driver_registered_count;
  UInt64 hidden_driver_registered_count;
  UInt64 visible_driver_started_count;
  UInt64 hidden_driver_started_count;
  UInt64 driver_registered_slot_bitmap;
  UInt64 driver_started_slot_bitmap;

  UInt64 driver_client_add_attempt_count;
  UInt64 driver_client_add_count;
  UInt64 driver_client_remove_attempt_count;
  UInt64 driver_client_remove_count;
  UInt64 global_start_attempt_count;
  UInt64 global_start_transition_count;
  UInt64 global_stop_attempt_count;
  UInt64 global_stop_transition_count;
  UInt64 seed_create_count;
  UInt64 seed_clear_count;
  UInt64 last_seed_create_host_ticks;
  UInt64 last_seed_clear_host_ticks;
  UInt64 last_cleared_seed;
  UInt64 last_cleared_seed_generation;
  UInt64 last_cleared_anchor_host_ticks;

  UInt32 client_slot_capacity;
  UInt32 reserved_header;
  OSVADiagnosticTransitionSnapshot last_driver_transition;
  OSVADiagnosticTransitionSnapshot last_core_transition;
  OSVADiagnosticZeroTimestampSnapshot zero_timestamp[2];
  OSVADiagnosticIOSnapshot io[2];
  OSVADiagnosticIOWorkLoopSnapshot io_work_loop[2];
  OSVADiagnosticDriverClientSlotSnapshot
      driver_client_slots[kOSVADiagnosticClientSlotCapacity];
  OSVADiagnosticCoreClientSlotSnapshot
      core_client_slots[kOSVADiagnosticClientSlotCapacity];
  UInt64 reserved[16];
} OSVADiagnosticSnapshot;

/*
 * Schema v1 is copied verbatim across Core Audio custom-property IPC. Freeze
 * every serialized member offset so an equal-width reorder cannot silently
 * retain the byte count while changing the wire meaning.
 */
#if defined(__cplusplus)
#define OSVA_DIAGNOSTIC_STATIC_ASSERT(condition, message)                     \
  static_assert((condition), message)
#else
#define OSVA_DIAGNOSTIC_STATIC_ASSERT(condition, message)                     \
  _Static_assert((condition), message)
#endif
#define OSVA_DIAGNOSTIC_ASSERT_OFFSET(type, member, expected)                 \
  OSVA_DIAGNOSTIC_STATIC_ASSERT(offsetof(type, member) == (expected),         \
                                #type "." #member " ABI offset changed")

OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticSnapshotSchemaVersion == 1 &&
        kOSVADiagnosticClientSlotCapacity == 64 &&
        kOSVADiagnosticSnapshotByteCount == 8608 &&
        kOSVADiagnosticSnapshotProperty == 0x6F734453,
    "diagnostic schema identity changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticEndpointNone == 0 &&
        kOSVADiagnosticEndpointVisibleInput == 1 &&
        kOSVADiagnosticEndpointHiddenWriter == 2,
    "diagnostic endpoint wire values changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticTransitionNone == 0 &&
        kOSVADiagnosticTransitionDriverClientAdded == 1 &&
        kOSVADiagnosticTransitionDriverClientRemoved == 2 &&
        kOSVADiagnosticTransitionIOStarted == 3 &&
        kOSVADiagnosticTransitionIOStopped == 4 &&
        kOSVADiagnosticTransitionSeedCreated == 5 &&
        kOSVADiagnosticTransitionSeedCleared == 6,
    "diagnostic transition wire values changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticDriverSlotRegistered == (1U << 0) &&
        kOSVADiagnosticDriverSlotStarted == (1U << 1) &&
        kOSVADiagnosticDriverSlotLeaseValid == (1U << 2),
    "diagnostic driver-slot flag values changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticRecordPresent == (1U << 0) &&
        kOSVADiagnosticRecordLastSuccessTupleValid == (1U << 1) &&
        kOSVADiagnosticRecordLastCallValid == (1U << 2) &&
        kOSVADiagnosticRecordUsedFallback == (1U << 3) &&
        kOSVADiagnosticRecordEpochMappingValid == (1U << 4),
    "diagnostic record flag values changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    kOSVADiagnosticSnapshotCoreInitialized == (UINT64_C(1) << 0) &&
        kOSVADiagnosticSnapshotTimelineActive == (UINT64_C(1) << 1) &&
        kOSVADiagnosticInvariantGlobalMatchesCoreSlots ==
            (UINT64_C(1) << 8) &&
        kOSVADiagnosticInvariantEndpointsMatchCoreSlots ==
            (UINT64_C(1) << 9) &&
        kOSVADiagnosticInvariantDriverStartsMatchCoreSlots ==
            (UINT64_C(1) << 10) &&
        kOSVADiagnosticInvariantIdleImpliesClockCleared ==
            (UINT64_C(1) << 11) &&
        kOSVADiagnosticInvariantActiveImpliesClockValid ==
            (UINT64_C(1) << 12) &&
        kOSVADiagnosticInvariantSlotCountsWithinCapacity ==
            (UINT64_C(1) << 13) &&
        kOSVADiagnosticInvariantStartStopBalancedAtIdle ==
            (UINT64_C(1) << 14) &&
        kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle ==
            (UINT64_C(1) << 15) &&
        kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed ==
            (UINT64_C(1) << 16) &&
        kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration ==
            (UINT64_C(1) << 17),
    "diagnostic snapshot flag values changed");

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, host_ticks, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, client_id, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot,
                              pre_global_active_count, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot,
                              post_global_active_count, 24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot,
                              driver_client_generation, 32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot,
                              core_session_id, 40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, reserved, 48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, type, 56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, endpoint_role,
                              60);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, slot_index, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticTransitionSnapshot, process_id, 68);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              generation, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              registration_host_ticks, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              start_host_ticks, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              last_transition_host_ticks, 24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              lease_session_id, 32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              lease_timeline_seed, 40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot, flags,
                              48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              device_object_id, 52);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              client_id, 56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              process_id, 60);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              endpoint_role, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              core_client_slot, 68);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot,
                              io_start_depth, 72);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticDriverClientSlotSnapshot, reserved,
                              76);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticCoreClientSlotSnapshot, session_id,
                              0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticCoreClientSlotSnapshot, client_id,
                              8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticCoreClientSlotSnapshot,
                              timeline_seed, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticCoreClientSlotSnapshot,
                              endpoint_role, 24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticCoreClientSlotSnapshot, reserved,
                              28);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, sequence, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              metadata_sequence, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              metadata_dropped_update_count, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              epoch_mapping_unavailable_count, 24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, call_count,
                              32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              successful_return_count, 40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              fallback_return_count, 48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              failed_return_count, 56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_call_host_ticks, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_sample_frame, 72);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_host_ticks, 80);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, last_seed,
                              88);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_seed_generation, 96);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_core_lifecycle_sequence, 104);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_call_core_lifecycle_sequence, 112);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot,
                              last_client_id, 120);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, last_status,
                              124);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, flags, 128);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticZeroTimestampSnapshot, reserved,
                              132);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, sequence, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, metadata_sequence, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              metadata_dropped_update_count, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, operation_call_count,
                              24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, valid_cycle_count, 32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, invalid_cycle_count,
                              40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              lease_unavailable_count, 48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              epoch_mapping_unavailable_count, 56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, core_ok_count, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, core_retry_count, 72);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, core_failure_count, 80);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, requested_frame_count,
                              88);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              transferred_frame_count, 96);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, gap_frame_count, 104);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_cycle_sample_frame, 112);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_cycle_host_ticks, 120);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_published_frame_seed, 128);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_published_seed_generation, 136);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_published_frame_session, 144);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_published_absolute_frame, 152);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_consumed_frame_seed, 160);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_consumed_seed_generation, 168);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_consumed_frame_session, 176);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot,
                              last_consumed_absolute_frame, 184);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, last_client_id, 192);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, last_status, 196);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, flags, 200);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOSnapshot, reserved, 204);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot, sequence, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot,
                              metadata_sequence, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot,
                              metadata_dropped_update_count, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot, current_count,
                              24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot, begin_count,
                              32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot, end_count, 40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot,
                              underflow_count, 48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot,
                              last_transition_host_ticks, 56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot,
                              last_client_id, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticIOWorkLoopSnapshot, flags, 68);

OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, schema_version, 0);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, struct_size, 4);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, snapshot_sequence, 8);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, captured_host_ticks, 16);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_instance_generation, 24);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, invariant_flags, 32);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_lifecycle_sequence, 40);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, core_lifecycle_sequence,
                              48);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, host_ticks_per_second,
                              56);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, timeline_seed, 64);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, current_seed_generation,
                              72);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, anchor_host_ticks, 80);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, last_issued_seed, 88);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, last_issued_session_id,
                              96);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, active_client_count, 104);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              visible_input_active_count, 112);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              hidden_writer_active_count, 120);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, core_active_slot_count,
                              128);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, core_active_slot_bitmap,
                              136);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, driver_registered_count,
                              144);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, driver_started_count,
                              152);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              visible_driver_registered_count, 160);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              hidden_driver_registered_count, 168);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              visible_driver_started_count, 176);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              hidden_driver_started_count, 184);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_registered_slot_bitmap, 192);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_started_slot_bitmap, 200);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_client_add_attempt_count, 208);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, driver_client_add_count,
                              216);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_client_remove_attempt_count, 224);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              driver_client_remove_count, 232);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              global_start_attempt_count, 240);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              global_start_transition_count, 248);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              global_stop_attempt_count, 256);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              global_stop_transition_count, 264);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, seed_create_count, 272);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, seed_clear_count, 280);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              last_seed_create_host_ticks, 288);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              last_seed_clear_host_ticks, 296);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, last_cleared_seed, 304);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              last_cleared_seed_generation, 312);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot,
                              last_cleared_anchor_host_ticks, 320);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, client_slot_capacity,
                              328);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, reserved_header, 332);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, last_driver_transition,
                              336);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, last_core_transition,
                              408);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, zero_timestamp, 480);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, io, 752);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, io_work_loop, 1168);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, driver_client_slots,
                              1312);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, core_client_slots, 6432);
OSVA_DIAGNOSTIC_ASSERT_OFFSET(OSVADiagnosticSnapshot, reserved, 8480);

OSVA_DIAGNOSTIC_STATIC_ASSERT(sizeof(OSVADiagnosticTransitionSnapshot) == 72,
                              "diagnostic transition ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    sizeof(OSVADiagnosticDriverClientSlotSnapshot) == 80,
    "diagnostic driver-slot ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    sizeof(OSVADiagnosticCoreClientSlotSnapshot) == 32,
    "diagnostic core-slot ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    sizeof(OSVADiagnosticZeroTimestampSnapshot) == 136,
    "diagnostic zero-timestamp ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(sizeof(OSVADiagnosticIOSnapshot) == 208,
                              "diagnostic I/O ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    sizeof(OSVADiagnosticIOWorkLoopSnapshot) == 72,
    "diagnostic I/O-work-loop ABI size changed");
OSVA_DIAGNOSTIC_STATIC_ASSERT(
    sizeof(OSVADiagnosticSnapshot) == kOSVADiagnosticSnapshotByteCount,
    "diagnostic snapshot ABI size changed");

#undef OSVA_DIAGNOSTIC_ASSERT_OFFSET
#undef OSVA_DIAGNOSTIC_STATIC_ASSERT

__attribute__((visibility("default"))) void *
OpensteamerVirtualMicrophone_Create(CFAllocatorRef allocator,
                                    CFUUIDRef requestedTypeUUID);

#if defined(OSVA_DRIVER_TESTING)
/// Restores the process-local production driver instance to its initial state.
/// Tests may call this only while no I/O operation is active.
OSStatus OSVADriverResetForTesting(void);

/// Fences the core lifecycle sequence after the next I/O call acquires its
/// client lease. The test build clears the fence before that call returns.
OSStatus OSVADriverFenceNextIOForTesting(void);

/// Fences the requested number of real core zero-timestamp calls. A value of
/// zero clears a previously requested fence count.
OSStatus OSVADriverFenceZeroTimeStampCallsForTesting(UInt32 callCount);

/// Pauses one successful zero-timestamp call after the exact core tuple has
/// been returned but before its diagnostic record is published.
OSStatus OSVADriverPauseNextZeroTimestampPublicationForTesting(void);

/// Reports whether the armed zero-timestamp publication is currently paused.
Boolean OSVADriverZeroTimestampPublicationIsPausedForTesting(void);

/// Releases a zero-timestamp publication paused by the test-only seam.
OSStatus OSVADriverResumeZeroTimestampPublicationForTesting(void);

/// Forces the next I/O work-loop current-count update to exhaust its bounded
/// compare-exchange attempts while leaving exact callback counters unchanged.
OSStatus OSVADriverForceNextIOWorkLoopCurrentCountDropForTesting(void);

enum {
  kOSVADriverTestDiagnosticRecordZeroTimestamp = 1,
  kOSVADriverTestDiagnosticRecordIO = 2,
  kOSVADriverTestDiagnosticRecordIOWorkLoopMetadata = 3,
};

/// Holds the next selected endpoint record writer after it acquires the
/// sequence, allowing tests to deterministically exercise bounded contention.
OSStatus OSVADriverHoldNextDiagnosticRecordWriterForTesting(
    UInt32 recordKind, UInt32 endpointRole);

Boolean OSVADriverDiagnosticRecordWriterIsHeldForTesting(void);

OSStatus OSVADriverResumeDiagnosticRecordWriterForTesting(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
