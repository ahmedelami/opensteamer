/*
 * Copyright 2026 opensteamer contributors.
 *
 * This AudioServerPlugIn was designed from Apple's MIT-licensed NullAudio
 * sample. The corresponding license is distributed as APPLE_SAMPLE_LICENSE.txt.
 * No BlackHole source code is used by this implementation.
 */

#include "OpensteamerVirtualMicrophoneDriver.h"

#include "OpensteamerVirtualAudioCore.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#if defined(OSVA_DRIVER_TESTING)
#include <sched.h>
#endif

#define OSVA_DRIVER_CLIENT_SLOT_COUNT ((size_t)64)
#define OSVA_ZERO_TIMESTAMP_RETRY_LIMIT 8U
#define OSVA_TIMESTAMP_CACHE_ATTEMPT_LIMIT 16U
#define OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT 16U
#define OSVA_DIAGNOSTIC_ENDPOINT_COUNT ((size_t)2)

static HRESULT OSVAQueryInterface(void *driver, REFIID uuid,
                                  LPVOID *outInterface);
static ULONG OSVAAddRef(void *driver);
static ULONG OSVARelease(void *driver);
static OSStatus OSVAInitialize(AudioServerPlugInDriverRef driver,
                               AudioServerPlugInHostRef host);
static OSStatus OSVACreateDevice(AudioServerPlugInDriverRef driver,
                                 CFDictionaryRef description,
                                 const AudioServerPlugInClientInfo *clientInfo,
                                 AudioObjectID *outDeviceObjectID);
static OSStatus OSVADestroyDevice(AudioServerPlugInDriverRef driver,
                                  AudioObjectID deviceObjectID);
static OSStatus
OSVAAddDeviceClient(AudioServerPlugInDriverRef driver,
                    AudioObjectID deviceObjectID,
                    const AudioServerPlugInClientInfo *clientInfo);
static OSStatus
OSVARemoveDeviceClient(AudioServerPlugInDriverRef driver,
                       AudioObjectID deviceObjectID,
                       const AudioServerPlugInClientInfo *clientInfo);
static OSStatus
OSVAPerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                     AudioObjectID deviceObjectID,
                                     UInt64 changeAction, void *changeInfo);
static OSStatus
OSVAAbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                   AudioObjectID deviceObjectID,
                                   UInt64 changeAction, void *changeInfo);
static Boolean OSVAHasProperty(AudioServerPlugInDriverRef driver,
                               AudioObjectID objectID, pid_t clientProcessID,
                               const AudioObjectPropertyAddress *address);
static OSStatus
OSVAIsPropertySettable(AudioServerPlugInDriverRef driver,
                       AudioObjectID objectID, pid_t clientProcessID,
                       const AudioObjectPropertyAddress *address,
                       Boolean *outIsSettable);
static OSStatus OSVAGetPropertyDataSize(
    AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
    UInt32 qualifierDataSize, const void *qualifierData, UInt32 *outDataSize);
static OSStatus OSVAGetPropertyData(AudioServerPlugInDriverRef driver,
                                    AudioObjectID objectID,
                                    pid_t clientProcessID,
                                    const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize,
                                    const void *qualifierData, UInt32 dataSize,
                                    UInt32 *outDataSize, void *outData);
static OSStatus OSVASetPropertyData(AudioServerPlugInDriverRef driver,
                                    AudioObjectID objectID,
                                    pid_t clientProcessID,
                                    const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize,
                                    const void *qualifierData, UInt32 dataSize,
                                    const void *data);
static OSStatus OSVAStartIO(AudioServerPlugInDriverRef driver,
                            AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus OSVAStopIO(AudioServerPlugInDriverRef driver,
                           AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus OSVAGetZeroTimeStamp(AudioServerPlugInDriverRef driver,
                                     AudioObjectID deviceObjectID,
                                     UInt32 clientID, Float64 *outSampleTime,
                                     UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus OSVAWillDoIOOperation(AudioServerPlugInDriverRef driver,
                                      AudioObjectID deviceObjectID,
                                      UInt32 clientID, UInt32 operationID,
                                      Boolean *outWillDo,
                                      Boolean *outWillDoInPlace);
static OSStatus
OSVABeginIOOperation(AudioServerPlugInDriverRef driver,
                     AudioObjectID deviceObjectID, UInt32 clientID,
                     UInt32 operationID, UInt32 ioBufferFrameSize,
                     const AudioServerPlugInIOCycleInfo *ioCycleInfo);
static OSStatus
OSVADoIOOperation(AudioServerPlugInDriverRef driver,
                  AudioObjectID deviceObjectID, AudioObjectID streamObjectID,
                  UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize,
                  const AudioServerPlugInIOCycleInfo *ioCycleInfo,
                  void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus
OSVAEndIOOperation(AudioServerPlugInDriverRef driver,
                   AudioObjectID deviceObjectID, UInt32 clientID,
                   UInt32 operationID, UInt32 ioBufferFrameSize,
                   const AudioServerPlugInIOCycleInfo *ioCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    OSVAQueryInterface,
    OSVAAddRef,
    OSVARelease,
    OSVAInitialize,
    OSVACreateDevice,
    OSVADestroyDevice,
    OSVAAddDeviceClient,
    OSVARemoveDeviceClient,
    OSVAPerformDeviceConfigurationChange,
    OSVAAbortDeviceConfigurationChange,
    OSVAHasProperty,
    OSVAIsPropertySettable,
    OSVAGetPropertyDataSize,
    OSVAGetPropertyData,
    OSVASetPropertyData,
    OSVAStartIO,
    OSVAStopIO,
    OSVAGetZeroTimeStamp,
    OSVAWillDoIOOperation,
    OSVABeginIOOperation,
    OSVADoIOOperation,
    OSVAEndIOOperation,
};
static AudioServerPlugInDriverInterface *gDriverInterfacePointer =
    &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePointer;

static _Atomic(ULONG) gReferenceCount = 1;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;

static OSVACore gCore;
static OSVAClientSlot gCoreClients[OSVA_DRIVER_CLIENT_SLOT_COUNT];
static OSVARingSlot gRingStorage[OSVA_PRODUCTION_RING_CAPACITY_FRAMES];
static _Atomic(bool) gCoreInitialized = false;
static _Atomic(uint64_t) gInvalidCycleTimestampCount = 0;

typedef struct {
  _Atomic(uint64_t) sequence;
  _Atomic(uint64_t) sample_frame;
  _Atomic(uint64_t) host_ticks;
  _Atomic(uint64_t) seed;
  _Atomic(uint64_t) lifecycle_sequence;
} OSVAZeroTimestampCache;

static OSVAZeroTimestampCache gZeroTimestampCache;
#if defined(OSVA_DRIVER_TESTING)
static _Atomic(bool) gFenceNextIOForTesting = false;
static _Atomic(uint32_t) gFenceZeroTimeStampCallCountForTesting = 0;
static _Atomic(bool) gPauseNextZeroTimestampPublicationForTesting = false;
static _Atomic(bool) gZeroTimestampPublicationPausedForTesting = false;
static _Atomic(bool) gResumeZeroTimestampPublicationForTesting = false;
static _Atomic(bool) gForceNextIOWorkLoopCurrentCountDropForTesting = false;
static _Atomic(uint32_t) gHeldDiagnosticRecordKindForTesting = 0;
static _Atomic(uint32_t) gHeldDiagnosticEndpointIndexForTesting = 0;
static _Atomic(bool) gDiagnosticRecordWriterHeldForTesting = false;
static _Atomic(bool) gResumeDiagnosticRecordWriterForTesting = false;
static bool OSVABeginLifecycleFenceForTesting(uint64_t *oddSequenceOut);
static void OSVAEndLifecycleFenceForTesting(uint64_t oddSequence);
#endif

typedef struct {
  bool registered;
  bool started;
  AudioObjectID device_object_id;
  UInt32 client_id;
  pid_t process_id;
  uint32_t io_start_depth;
  uint64_t generation;
  uint64_t registration_host_ticks;
  uint64_t start_host_ticks;
  uint64_t last_transition_host_ticks;
  OSVAClientLease lease;
} OSVADriverClient;

static OSVADriverClient gDriverClients[OSVA_DRIVER_CLIENT_SLOT_COUNT];

typedef struct {
  uint64_t driver_instance_generation;
  uint64_t snapshot_observation_sequence;
  uint64_t lifecycle_sequence;
  uint64_t driver_client_add_attempt_count;
  uint64_t driver_client_add_count;
  uint64_t driver_client_remove_attempt_count;
  uint64_t driver_client_remove_count;
  uint64_t global_start_attempt_count;
  uint64_t global_start_transition_count;
  uint64_t global_stop_attempt_count;
  uint64_t global_stop_transition_count;
  uint64_t seed_create_count;
  uint64_t seed_clear_count;
  uint64_t current_seed_generation;
  uint64_t last_seed_create_host_ticks;
  uint64_t last_seed_clear_host_ticks;
  uint64_t last_cleared_seed;
  uint64_t last_cleared_seed_generation;
  uint64_t last_cleared_anchor_host_ticks;
  OSVADiagnosticTransitionSnapshot last_driver_transition;
  OSVADiagnosticTransitionSnapshot last_core_transition;
} OSVADiagnosticLifecycleState;

typedef struct {
  _Atomic(uint64_t) sequence;
  _Atomic(uint64_t) active_publisher_count;
  _Atomic(uint64_t) metadata_sequence;
  _Atomic(uint64_t) metadata_dropped_update_count;
  _Atomic(uint64_t) epoch_mapping_unavailable_count;
  _Atomic(uint64_t) call_count;
  _Atomic(uint64_t) successful_return_count;
  _Atomic(uint64_t) fallback_return_count;
  _Atomic(uint64_t) failed_return_count;
  _Atomic(uint64_t) last_call_host_ticks;
  _Atomic(uint64_t) last_sample_frame;
  _Atomic(uint64_t) last_host_ticks;
  _Atomic(uint64_t) last_seed;
  _Atomic(uint64_t) last_seed_generation;
  _Atomic(uint64_t) last_core_lifecycle_sequence;
  _Atomic(uint64_t) last_call_core_lifecycle_sequence;
  _Atomic(uint32_t) last_client_id;
  _Atomic(int32_t) last_status;
  _Atomic(uint32_t) flags;
} OSVAAtomicZeroTimestampDiagnostics;

typedef struct {
  _Atomic(uint64_t) sequence;
  _Atomic(uint64_t) active_publisher_count;
  _Atomic(uint64_t) metadata_sequence;
  _Atomic(uint64_t) metadata_dropped_update_count;
  _Atomic(uint64_t) operation_call_count;
  _Atomic(uint64_t) valid_cycle_count;
  _Atomic(uint64_t) invalid_cycle_count;
  _Atomic(uint64_t) lease_unavailable_count;
  _Atomic(uint64_t) epoch_mapping_unavailable_count;
  _Atomic(uint64_t) core_ok_count;
  _Atomic(uint64_t) core_retry_count;
  _Atomic(uint64_t) core_failure_count;
  _Atomic(uint64_t) requested_frame_count;
  _Atomic(uint64_t) transferred_frame_count;
  _Atomic(uint64_t) gap_frame_count;
  _Atomic(uint64_t) last_cycle_sample_frame;
  _Atomic(uint64_t) last_cycle_host_ticks;
  _Atomic(uint64_t) last_published_frame_seed;
  _Atomic(uint64_t) last_published_seed_generation;
  _Atomic(uint64_t) last_published_frame_session;
  _Atomic(uint64_t) last_published_absolute_frame;
  _Atomic(uint64_t) last_consumed_frame_seed;
  _Atomic(uint64_t) last_consumed_seed_generation;
  _Atomic(uint64_t) last_consumed_frame_session;
  _Atomic(uint64_t) last_consumed_absolute_frame;
  _Atomic(uint32_t) last_client_id;
  _Atomic(int32_t) last_status;
  _Atomic(uint32_t) flags;
} OSVAAtomicIODiagnostics;

typedef struct {
  _Atomic(uint64_t) sequence;
  _Atomic(uint64_t) active_publisher_count;
  _Atomic(uint64_t) metadata_sequence;
  _Atomic(uint64_t) metadata_dropped_update_count;
  _Atomic(uint64_t) current_count;
  _Atomic(uint64_t) begin_count;
  _Atomic(uint64_t) end_count;
  _Atomic(uint64_t) underflow_count;
  _Atomic(uint64_t) last_transition_host_ticks;
  _Atomic(uint32_t) last_client_id;
  _Atomic(uint32_t) flags;
} OSVAAtomicIOWorkLoopDiagnostics;

static uint64_t gLastDriverInstanceGeneration = 0;
static OSVADiagnosticLifecycleState gDiagnosticLifecycle;
static OSVAAtomicZeroTimestampDiagnostics
    gZeroTimestampDiagnostics[OSVA_DIAGNOSTIC_ENDPOINT_COUNT];
static OSVAAtomicIODiagnostics gIODiagnostics[OSVA_DIAGNOSTIC_ENDPOINT_COUNT];
static OSVAAtomicIOWorkLoopDiagnostics
    gIOWorkLoopDiagnostics[OSVA_DIAGNOSTIC_ENDPOINT_COUNT];

typedef struct {
  bool valid_cycle;
  bool lease_available;
  bool epoch_mapping_available;
  bool core_called;
  bool writer;
  bool has_transferred_frame;
  uint64_t requested_frames;
  uint64_t transferred_frames;
  uint64_t gap_frames;
  uint64_t cycle_sample_frame;
  uint64_t cycle_host_ticks;
  uint64_t seed_generation;
  uint64_t transferred_seed;
  uint64_t transferred_session;
  uint64_t transferred_absolute_frame;
  UInt32 client_id;
  OSVAStatus status;
} OSVAIODiagnosticObservation;

_Static_assert(OSVA_DRIVER_CLIENT_SLOT_COUNT ==
                   kOSVADiagnosticClientSlotCapacity,
               "diagnostic ABI must cover every driver client slot");
_Static_assert(sizeof(OSVADiagnosticTransitionSnapshot) == 72,
               "diagnostic transition ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticDriverClientSlotSnapshot) == 80,
               "diagnostic driver-slot ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticCoreClientSlotSnapshot) == 32,
               "diagnostic core-slot ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticZeroTimestampSnapshot) == 136,
               "diagnostic zero-timestamp ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticIOSnapshot) == 208,
               "diagnostic I/O ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticIOWorkLoopSnapshot) == 72,
               "diagnostic I/O-work-loop ABI changed without a version bump");
_Static_assert(sizeof(OSVADiagnosticSnapshot) ==
                   kOSVADiagnosticSnapshotByteCount,
               "diagnostic snapshot ABI changed without a version bump");

static size_t OSVADiagnosticEndpointIndex(OSVAEndpoint endpoint) {
  return endpoint == OSVA_ENDPOINT_HIDDEN_WRITER ? 1U : 0U;
}

static void OSVAIncrementDiagnosticCounter(uint64_t *counter) {
  if (*counter != UINT64_MAX) {
    *counter += 1;
  }
}

static void OSVAAdvanceDiagnosticLifecycleSequence(void) {
  OSVAIncrementDiagnosticCounter(&gDiagnosticLifecycle.lifecycle_sequence);
}

static void OSVARecordDiagnosticTransition(
    OSVADiagnosticTransitionSnapshot *transition,
    OSVADiagnosticTransitionType type, OSVAEndpoint endpoint, size_t slotIndex,
    uint64_t clientID, pid_t processID, uint64_t driverClientGeneration,
    uint64_t coreSessionID, uint64_t preGlobalCount, uint64_t postGlobalCount,
    uint64_t hostTicks) {
  *transition = (OSVADiagnosticTransitionSnapshot){
      .host_ticks = hostTicks,
      .client_id = clientID,
      .pre_global_active_count = preGlobalCount,
      .post_global_active_count = postGlobalCount,
      .driver_client_generation = driverClientGeneration,
      .core_session_id = coreSessionID,
      .type = (UInt32)type,
      .endpoint_role = (UInt32)endpoint,
      .slot_index = slotIndex < OSVA_DRIVER_CLIENT_SLOT_COUNT
                        ? (UInt32)slotIndex
                        : OSVA_INVALID_CLIENT_SLOT,
      .process_id = (SInt32)processID,
  };
}

static bool OSVADiagnosticAtomicsAreLockFree(void) {
  for (size_t index = 0; index < OSVA_DIAGNOSTIC_ENDPOINT_COUNT; ++index) {
    const OSVAAtomicZeroTimestampDiagnostics *zero =
        &gZeroTimestampDiagnostics[index];
    const OSVAAtomicIODiagnostics *io = &gIODiagnostics[index];
    const OSVAAtomicIOWorkLoopDiagnostics *workLoop =
        &gIOWorkLoopDiagnostics[index];
    if (!atomic_is_lock_free(&zero->sequence) ||
        !atomic_is_lock_free(&zero->active_publisher_count) ||
        !atomic_is_lock_free(&zero->metadata_sequence) ||
        !atomic_is_lock_free(&zero->metadata_dropped_update_count) ||
        !atomic_is_lock_free(&zero->epoch_mapping_unavailable_count) ||
        !atomic_is_lock_free(&zero->call_count) ||
        !atomic_is_lock_free(&zero->successful_return_count) ||
        !atomic_is_lock_free(&zero->fallback_return_count) ||
        !atomic_is_lock_free(&zero->failed_return_count) ||
        !atomic_is_lock_free(&zero->last_call_host_ticks) ||
        !atomic_is_lock_free(&zero->last_sample_frame) ||
        !atomic_is_lock_free(&zero->last_host_ticks) ||
        !atomic_is_lock_free(&zero->last_seed) ||
        !atomic_is_lock_free(&zero->last_seed_generation) ||
        !atomic_is_lock_free(&zero->last_core_lifecycle_sequence) ||
        !atomic_is_lock_free(&zero->last_call_core_lifecycle_sequence) ||
        !atomic_is_lock_free(&zero->last_client_id) ||
        !atomic_is_lock_free(&zero->last_status) ||
        !atomic_is_lock_free(&zero->flags) ||
        !atomic_is_lock_free(&io->sequence) ||
        !atomic_is_lock_free(&io->active_publisher_count) ||
        !atomic_is_lock_free(&io->metadata_sequence) ||
        !atomic_is_lock_free(&io->metadata_dropped_update_count) ||
        !atomic_is_lock_free(&io->operation_call_count) ||
        !atomic_is_lock_free(&io->valid_cycle_count) ||
        !atomic_is_lock_free(&io->invalid_cycle_count) ||
        !atomic_is_lock_free(&io->lease_unavailable_count) ||
        !atomic_is_lock_free(&io->epoch_mapping_unavailable_count) ||
        !atomic_is_lock_free(&io->core_ok_count) ||
        !atomic_is_lock_free(&io->core_retry_count) ||
        !atomic_is_lock_free(&io->core_failure_count) ||
        !atomic_is_lock_free(&io->requested_frame_count) ||
        !atomic_is_lock_free(&io->transferred_frame_count) ||
        !atomic_is_lock_free(&io->gap_frame_count) ||
        !atomic_is_lock_free(&io->last_cycle_sample_frame) ||
        !atomic_is_lock_free(&io->last_cycle_host_ticks) ||
        !atomic_is_lock_free(&io->last_published_frame_seed) ||
        !atomic_is_lock_free(&io->last_published_seed_generation) ||
        !atomic_is_lock_free(&io->last_published_frame_session) ||
        !atomic_is_lock_free(&io->last_published_absolute_frame) ||
        !atomic_is_lock_free(&io->last_consumed_frame_seed) ||
        !atomic_is_lock_free(&io->last_consumed_seed_generation) ||
        !atomic_is_lock_free(&io->last_consumed_frame_session) ||
        !atomic_is_lock_free(&io->last_consumed_absolute_frame) ||
        !atomic_is_lock_free(&io->last_client_id) ||
        !atomic_is_lock_free(&io->last_status) ||
        !atomic_is_lock_free(&io->flags) ||
        !atomic_is_lock_free(&workLoop->sequence) ||
        !atomic_is_lock_free(&workLoop->active_publisher_count) ||
        !atomic_is_lock_free(&workLoop->metadata_sequence) ||
        !atomic_is_lock_free(&workLoop->metadata_dropped_update_count) ||
        !atomic_is_lock_free(&workLoop->current_count) ||
        !atomic_is_lock_free(&workLoop->begin_count) ||
        !atomic_is_lock_free(&workLoop->end_count) ||
        !atomic_is_lock_free(&workLoop->underflow_count) ||
        !atomic_is_lock_free(&workLoop->last_transition_host_ticks) ||
        !atomic_is_lock_free(&workLoop->last_client_id) ||
        !atomic_is_lock_free(&workLoop->flags)) {
      return false;
    }
  }
  return true;
}

static void OSVAResetDiagnosticAtomics(void) {
  for (size_t index = 0; index < OSVA_DIAGNOSTIC_ENDPOINT_COUNT; ++index) {
    OSVAAtomicZeroTimestampDiagnostics *zero =
        &gZeroTimestampDiagnostics[index];
    OSVAAtomicIODiagnostics *io = &gIODiagnostics[index];
    OSVAAtomicIOWorkLoopDiagnostics *workLoop =
        &gIOWorkLoopDiagnostics[index];
    atomic_store_explicit(&zero->sequence, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->active_publisher_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->metadata_sequence, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->metadata_dropped_update_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->epoch_mapping_unavailable_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->call_count, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->successful_return_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->fallback_return_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->failed_return_count, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->last_call_host_ticks, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->last_sample_frame, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->last_host_ticks, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->last_seed, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->last_seed_generation, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->last_core_lifecycle_sequence, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->last_call_core_lifecycle_sequence, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&zero->last_client_id, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->last_status, 0, memory_order_relaxed);
    atomic_store_explicit(&zero->flags, 0, memory_order_relaxed);

    atomic_store_explicit(&io->sequence, 0, memory_order_relaxed);
    atomic_store_explicit(&io->active_publisher_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->metadata_sequence, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->metadata_dropped_update_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->operation_call_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->valid_cycle_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->invalid_cycle_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->lease_unavailable_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->epoch_mapping_unavailable_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->core_ok_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->core_retry_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->core_failure_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->requested_frame_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->transferred_frame_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->gap_frame_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io->last_cycle_sample_frame, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_cycle_host_ticks, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_published_frame_seed, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_published_seed_generation, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_published_frame_session, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_published_absolute_frame, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_consumed_frame_seed, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_consumed_seed_generation, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_consumed_frame_session, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_consumed_absolute_frame, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&io->last_client_id, 0, memory_order_relaxed);
    atomic_store_explicit(&io->last_status, 0, memory_order_relaxed);
    atomic_store_explicit(&io->flags, 0, memory_order_relaxed);

    atomic_store_explicit(&workLoop->sequence, 0, memory_order_relaxed);
    atomic_store_explicit(&workLoop->active_publisher_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&workLoop->metadata_sequence, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&workLoop->metadata_dropped_update_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&workLoop->current_count, 0, memory_order_relaxed);
    atomic_store_explicit(&workLoop->begin_count, 0, memory_order_relaxed);
    atomic_store_explicit(&workLoop->end_count, 0, memory_order_relaxed);
    atomic_store_explicit(&workLoop->underflow_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&workLoop->last_transition_host_ticks, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&workLoop->last_client_id, 0, memory_order_relaxed);
    atomic_store_explicit(&workLoop->flags, 0, memory_order_relaxed);
  }
}

static bool OSVABeginDiagnosticRecord(_Atomic(uint64_t) *sequence,
                                      uint64_t *oddSequenceOut) {
  for (unsigned attempt = 0; attempt < OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT;
       ++attempt) {
    uint64_t observed =
        atomic_load_explicit(sequence, memory_order_acquire);
    if ((observed & UINT64_C(1)) != 0 || observed > UINT64_MAX - 2) {
      continue;
    }
    const uint64_t oddSequence = observed + 1;
    if (atomic_compare_exchange_weak_explicit(
            sequence, &observed, oddSequence, memory_order_acq_rel,
            memory_order_acquire)) {
      *oddSequenceOut = oddSequence;
      return true;
    }
  }
  return false;
}

static void OSVAEndDiagnosticRecord(_Atomic(uint64_t) *sequence,
                                    uint64_t oddSequence) {
  atomic_store_explicit(sequence, oddSequence + 1, memory_order_release);
}

#if defined(OSVA_DRIVER_TESTING)
static void OSVAMaybeHoldDiagnosticRecordWriterForTesting(
    UInt32 recordKind, size_t endpointIndex) {
  if (atomic_load_explicit(&gHeldDiagnosticEndpointIndexForTesting,
                           memory_order_acquire) != endpointIndex) {
    return;
  }
  uint32_t expected = recordKind;
  if (!atomic_compare_exchange_strong_explicit(
          &gHeldDiagnosticRecordKindForTesting, &expected, 0,
          memory_order_acq_rel, memory_order_acquire)) {
    return;
  }
  atomic_store_explicit(&gDiagnosticRecordWriterHeldForTesting, true,
                        memory_order_release);
  while (!atomic_load_explicit(&gResumeDiagnosticRecordWriterForTesting,
                               memory_order_acquire)) {
    sched_yield();
  }
  atomic_store_explicit(&gResumeDiagnosticRecordWriterForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gDiagnosticRecordWriterHeldForTesting, false,
                        memory_order_release);
}
#endif

static void OSVAPublishZeroTimestampDiagnostic(
    OSVAEndpoint endpoint, UInt32 clientID, uint64_t callHostTicks,
    uint64_t coreLifecycleSequence, OSVAStatus status,
    const OSVAZeroTimestamp *timestamp, uint64_t seedGeneration,
    bool epochMappingAvailable, bool usedFallback) {
  OSVAAtomicZeroTimestampDiagnostics *record =
      &gZeroTimestampDiagnostics[OSVADiagnosticEndpointIndex(endpoint)];
  (void)atomic_fetch_add_explicit(&record->active_publisher_count, UINT64_C(1),
                                  memory_order_acq_rel);
  (void)atomic_fetch_add_explicit(&record->call_count, UINT64_C(1),
                                  memory_order_relaxed);
  if (status == OSVA_STATUS_OK && timestamp != NULL) {
    (void)atomic_fetch_add_explicit(&record->successful_return_count,
                                    UINT64_C(1), memory_order_relaxed);
    if (usedFallback) {
      (void)atomic_fetch_add_explicit(&record->fallback_return_count,
                                      UINT64_C(1), memory_order_relaxed);
    }
    if (!epochMappingAvailable) {
      (void)atomic_fetch_add_explicit(
          &record->epoch_mapping_unavailable_count, UINT64_C(1),
          memory_order_relaxed);
    }
  } else {
    (void)atomic_fetch_add_explicit(&record->failed_return_count, UINT64_C(1),
                                    memory_order_relaxed);
  }

  uint64_t oddMetadataSequence = 0;
  if (OSVABeginDiagnosticRecord(&record->metadata_sequence,
                                &oddMetadataSequence)) {
#if defined(OSVA_DRIVER_TESTING)
    OSVAMaybeHoldDiagnosticRecordWriterForTesting(
        kOSVADriverTestDiagnosticRecordZeroTimestamp,
        OSVADiagnosticEndpointIndex(endpoint));
#endif
    atomic_store_explicit(&record->last_call_host_ticks, callHostTicks,
                          memory_order_relaxed);
    atomic_store_explicit(&record->last_call_core_lifecycle_sequence,
                          coreLifecycleSequence, memory_order_relaxed);
    atomic_store_explicit(&record->last_client_id, clientID,
                          memory_order_relaxed);
    atomic_store_explicit(&record->last_status, (int32_t)status,
                          memory_order_relaxed);
    uint32_t flags =
        atomic_load_explicit(&record->flags, memory_order_relaxed);
    if (status == OSVA_STATUS_OK && timestamp != NULL) {
      atomic_store_explicit(&record->last_sample_frame,
                            timestamp->sample_frame, memory_order_relaxed);
      atomic_store_explicit(&record->last_host_ticks, timestamp->host_ticks,
                            memory_order_relaxed);
      atomic_store_explicit(&record->last_seed, timestamp->seed,
                            memory_order_relaxed);
      atomic_store_explicit(&record->last_seed_generation, seedGeneration,
                            memory_order_relaxed);
      atomic_store_explicit(&record->last_core_lifecycle_sequence,
                            coreLifecycleSequence, memory_order_relaxed);
      flags = kOSVADiagnosticRecordPresent |
              kOSVADiagnosticRecordLastSuccessTupleValid |
              kOSVADiagnosticRecordLastCallValid;
      if (epochMappingAvailable) {
        flags |= kOSVADiagnosticRecordEpochMappingValid;
      }
      if (usedFallback) {
        flags |= kOSVADiagnosticRecordUsedFallback;
      }
    } else {
      /* A failed call must not destroy the last tuple that HAL did receive. */
      flags &= kOSVADiagnosticRecordLastSuccessTupleValid |
               kOSVADiagnosticRecordUsedFallback |
               kOSVADiagnosticRecordEpochMappingValid;
      flags |= kOSVADiagnosticRecordPresent;
    }
    atomic_store_explicit(&record->flags, flags, memory_order_relaxed);
    OSVAEndDiagnosticRecord(&record->metadata_sequence, oddMetadataSequence);
  } else {
    (void)atomic_fetch_add_explicit(&record->metadata_dropped_update_count,
                                    UINT64_C(1), memory_order_relaxed);
  }
  (void)atomic_fetch_add_explicit(&record->sequence, UINT64_C(1),
                                  memory_order_release);
  (void)atomic_fetch_sub_explicit(&record->active_publisher_count,
                                  UINT64_C(1), memory_order_release);
}

static void OSVAPublishIODiagnostic(OSVAEndpoint endpoint,
                                    OSVAIODiagnosticObservation observation) {
  OSVAAtomicIODiagnostics *record =
      &gIODiagnostics[OSVADiagnosticEndpointIndex(endpoint)];
  (void)atomic_fetch_add_explicit(&record->active_publisher_count, UINT64_C(1),
                                  memory_order_acq_rel);
  (void)atomic_fetch_add_explicit(&record->operation_call_count, UINT64_C(1),
                                  memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&record->requested_frame_count,
                                  observation.requested_frames,
                                  memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&record->transferred_frame_count,
                                  observation.transferred_frames,
                                  memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&record->gap_frame_count,
                                  observation.gap_frames,
                                  memory_order_relaxed);
  if (observation.valid_cycle) {
    (void)atomic_fetch_add_explicit(&record->valid_cycle_count, UINT64_C(1),
                                    memory_order_relaxed);
  } else {
    (void)atomic_fetch_add_explicit(&record->invalid_cycle_count, UINT64_C(1),
                                    memory_order_relaxed);
  }
  if (observation.valid_cycle && !observation.lease_available) {
    (void)atomic_fetch_add_explicit(&record->lease_unavailable_count,
                                    UINT64_C(1), memory_order_relaxed);
  }
  if (observation.valid_cycle && observation.lease_available &&
      !observation.epoch_mapping_available) {
    (void)atomic_fetch_add_explicit(
        &record->epoch_mapping_unavailable_count, UINT64_C(1),
        memory_order_relaxed);
  }
  if (observation.core_called) {
    if (observation.status == OSVA_STATUS_OK) {
      (void)atomic_fetch_add_explicit(&record->core_ok_count, UINT64_C(1),
                                      memory_order_relaxed);
    } else if (observation.status == OSVA_STATUS_RETRY) {
      (void)atomic_fetch_add_explicit(&record->core_retry_count, UINT64_C(1),
                                      memory_order_relaxed);
    } else {
      (void)atomic_fetch_add_explicit(&record->core_failure_count, UINT64_C(1),
                                      memory_order_relaxed);
    }
  }

  uint64_t oddMetadataSequence = 0;
  if (OSVABeginDiagnosticRecord(&record->metadata_sequence,
                                &oddMetadataSequence)) {
#if defined(OSVA_DRIVER_TESTING)
    OSVAMaybeHoldDiagnosticRecordWriterForTesting(
        kOSVADriverTestDiagnosticRecordIO,
        OSVADiagnosticEndpointIndex(endpoint));
#endif
    atomic_store_explicit(&record->last_cycle_sample_frame,
                          observation.cycle_sample_frame,
                          memory_order_relaxed);
    atomic_store_explicit(&record->last_cycle_host_ticks,
                          observation.cycle_host_ticks, memory_order_relaxed);
    atomic_store_explicit(&record->last_client_id, observation.client_id,
                          memory_order_relaxed);
    atomic_store_explicit(&record->last_status, (int32_t)observation.status,
                          memory_order_relaxed);
    uint32_t flags =
        atomic_load_explicit(&record->flags, memory_order_relaxed);
    flags &= kOSVADiagnosticRecordLastSuccessTupleValid |
             kOSVADiagnosticRecordEpochMappingValid;
    flags |= kOSVADiagnosticRecordPresent;
    if (observation.valid_cycle) {
      flags |= kOSVADiagnosticRecordLastCallValid;
    }
    if (observation.has_transferred_frame) {
      flags |= kOSVADiagnosticRecordLastSuccessTupleValid;
      if (observation.epoch_mapping_available) {
        flags |= kOSVADiagnosticRecordEpochMappingValid;
      } else {
        flags &= (uint32_t)~kOSVADiagnosticRecordEpochMappingValid;
      }
      if (observation.writer) {
        atomic_store_explicit(&record->last_published_frame_seed,
                              observation.transferred_seed,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_published_seed_generation,
                              observation.seed_generation,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_published_frame_session,
                              observation.transferred_session,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_published_absolute_frame,
                              observation.transferred_absolute_frame,
                              memory_order_relaxed);
      } else {
        atomic_store_explicit(&record->last_consumed_frame_seed,
                              observation.transferred_seed,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_consumed_seed_generation,
                              observation.seed_generation,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_consumed_frame_session,
                              observation.transferred_session,
                              memory_order_relaxed);
        atomic_store_explicit(&record->last_consumed_absolute_frame,
                              observation.transferred_absolute_frame,
                              memory_order_relaxed);
      }
    }
    atomic_store_explicit(&record->flags, flags, memory_order_relaxed);
    OSVAEndDiagnosticRecord(&record->metadata_sequence, oddMetadataSequence);
  } else {
    (void)atomic_fetch_add_explicit(&record->metadata_dropped_update_count,
                                    UINT64_C(1), memory_order_relaxed);
  }
  (void)atomic_fetch_add_explicit(&record->sequence, UINT64_C(1),
                                  memory_order_release);
  (void)atomic_fetch_sub_explicit(&record->active_publisher_count,
                                  UINT64_C(1), memory_order_release);
}

static bool OSVAUpdateIOWorkLoopCurrentCount(
    OSVAAtomicIOWorkLoopDiagnostics *record, bool isBegin) {
#if defined(OSVA_DRIVER_TESTING)
  const bool forceAllAttemptsToFail = atomic_exchange_explicit(
      &gForceNextIOWorkLoopCurrentCountDropForTesting, false,
      memory_order_acq_rel);
#endif
  for (unsigned attempt = 0; attempt < OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT;
       ++attempt) {
    uint64_t current = atomic_load_explicit(&record->current_count,
                                            memory_order_relaxed);
    if (!isBegin && current == 0) {
      (void)atomic_fetch_add_explicit(&record->underflow_count, UINT64_C(1),
                                      memory_order_relaxed);
      return true;
    }
    if (isBegin && current == UINT64_MAX) {
      return false;
    }
#if defined(OSVA_DRIVER_TESTING)
    if (forceAllAttemptsToFail) {
      continue;
    }
#endif
    const uint64_t desired = isBegin ? current + 1 : current - 1;
    if (atomic_compare_exchange_weak_explicit(
            &record->current_count, &current, desired, memory_order_relaxed,
            memory_order_relaxed)) {
      return true;
    }
  }
  return false;
}

static void OSVAPublishIOWorkLoopDiagnostic(OSVAEndpoint endpoint,
                                            UInt32 clientID, bool isBegin) {
  OSVAAtomicIOWorkLoopDiagnostics *record =
      &gIOWorkLoopDiagnostics[OSVADiagnosticEndpointIndex(endpoint)];

  /*
   * These four counters are decisive state, so every callback updates them.
   * active_publisher_count lets the bounded snapshot reader reject a partial
   * multi-atomic transition without ever making the RT writer wait.
   */
  (void)atomic_fetch_add_explicit(&record->active_publisher_count, UINT64_C(1),
                                  memory_order_acq_rel);
  if (isBegin) {
    (void)atomic_fetch_add_explicit(&record->begin_count, UINT64_C(1),
                                    memory_order_relaxed);
  } else {
    (void)atomic_fetch_add_explicit(&record->end_count, UINT64_C(1),
                                    memory_order_relaxed);
  }
  if (!OSVAUpdateIOWorkLoopCurrentCount(record, isBegin)) {
    (void)atomic_fetch_add_explicit(&record->metadata_dropped_update_count,
                                    UINT64_C(1), memory_order_relaxed);
  }

  uint64_t oddMetadataSequence = 0;
  if (OSVABeginDiagnosticRecord(&record->metadata_sequence,
                                &oddMetadataSequence)) {
#if defined(OSVA_DRIVER_TESTING)
    OSVAMaybeHoldDiagnosticRecordWriterForTesting(
        kOSVADriverTestDiagnosticRecordIOWorkLoopMetadata,
        OSVADiagnosticEndpointIndex(endpoint));
#endif
    atomic_store_explicit(&record->last_transition_host_ticks,
                          mach_absolute_time(), memory_order_relaxed);
    atomic_store_explicit(&record->last_client_id, clientID,
                          memory_order_relaxed);
    atomic_store_explicit(
        &record->flags,
        kOSVADiagnosticRecordPresent | kOSVADiagnosticRecordLastCallValid,
        memory_order_relaxed);
    OSVAEndDiagnosticRecord(&record->metadata_sequence, oddMetadataSequence);
  } else {
    (void)atomic_fetch_add_explicit(&record->metadata_dropped_update_count,
                                    UINT64_C(1), memory_order_relaxed);
  }

  (void)atomic_fetch_add_explicit(&record->sequence, UINT64_C(1),
                                  memory_order_release);
  (void)atomic_fetch_sub_explicit(&record->active_publisher_count,
                                  UINT64_C(1), memory_order_release);
}

typedef enum {
  kOSVAObjectInvalid = 0,
  kOSVAObjectPlugIn,
  kOSVAObjectDevice,
  kOSVAObjectStream,
  kOSVAObjectVolume,
  kOSVAObjectMute,
} OSVAObjectKind;

static bool OSVAIsVisibleDevice(AudioObjectID objectID) {
  return objectID == kOSVAObjectIDVisibleInputDevice;
}

static bool OSVAIsHiddenDevice(AudioObjectID objectID) {
  return objectID == kOSVAObjectIDHiddenWriterDevice;
}

static bool OSVAIsDevice(AudioObjectID objectID) {
  return OSVAIsVisibleDevice(objectID) || OSVAIsHiddenDevice(objectID);
}

static bool OSVAIsVisibleObject(AudioObjectID objectID) {
  return objectID >= kOSVAObjectIDVisibleInputDevice &&
         objectID <= kOSVAObjectIDVisibleInputMute;
}

static bool OSVAIsHiddenObject(AudioObjectID objectID) {
  return objectID >= kOSVAObjectIDHiddenWriterDevice &&
         objectID <= kOSVAObjectIDHiddenWriterMute;
}

static OSVAObjectKind OSVAGetObjectKind(AudioObjectID objectID) {
  switch (objectID) {
  case kOSVAObjectIDPlugIn:
    return kOSVAObjectPlugIn;
  case kOSVAObjectIDVisibleInputDevice:
  case kOSVAObjectIDHiddenWriterDevice:
    return kOSVAObjectDevice;
  case kOSVAObjectIDVisibleInputStream:
  case kOSVAObjectIDHiddenWriterStream:
    return kOSVAObjectStream;
  case kOSVAObjectIDVisibleInputVolume:
  case kOSVAObjectIDHiddenWriterVolume:
    return kOSVAObjectVolume;
  case kOSVAObjectIDVisibleInputMute:
  case kOSVAObjectIDHiddenWriterMute:
    return kOSVAObjectMute;
  default:
    return kOSVAObjectInvalid;
  }
}

static AudioObjectID OSVAOwnerForObject(AudioObjectID objectID) {
  if (OSVAIsVisibleObject(objectID)) {
    return objectID == kOSVAObjectIDVisibleInputDevice
               ? kOSVAObjectIDPlugIn
               : kOSVAObjectIDVisibleInputDevice;
  }
  if (OSVAIsHiddenObject(objectID)) {
    return objectID == kOSVAObjectIDHiddenWriterDevice
               ? kOSVAObjectIDPlugIn
               : kOSVAObjectIDHiddenWriterDevice;
  }
  return kAudioObjectUnknown;
}

static bool OSVAIsMainElement(const AudioObjectPropertyAddress *address) {
  return address->mElement == kAudioObjectPropertyElementMain;
}

static bool OSVAIsGlobal(const AudioObjectPropertyAddress *address) {
  return address->mScope == kAudioObjectPropertyScopeGlobal;
}

static bool OSVAIsInput(const AudioObjectPropertyAddress *address) {
  return address->mScope == kAudioObjectPropertyScopeInput;
}

static bool OSVAIsOutput(const AudioObjectPropertyAddress *address) {
  return address->mScope == kAudioObjectPropertyScopeOutput;
}

static bool OSVAIsAnyDeviceScope(const AudioObjectPropertyAddress *address) {
  return OSVAIsGlobal(address) || OSVAIsInput(address) || OSVAIsOutput(address);
}

static bool OSVAIsRoleScope(AudioObjectID deviceObjectID,
                            const AudioObjectPropertyAddress *address) {
  return (OSVAIsVisibleDevice(deviceObjectID) && OSVAIsInput(address)) ||
         (OSVAIsHiddenDevice(deviceObjectID) && OSVAIsOutput(address));
}

static bool OSVAHasPlugInProperty(const AudioObjectPropertyAddress *address) {
  if (!OSVAIsMainElement(address) || !OSVAIsGlobal(address)) {
    return false;
  }
  switch (address->mSelector) {
  case kAudioObjectPropertyBaseClass:
  case kAudioObjectPropertyClass:
  case kAudioObjectPropertyOwner:
  case kAudioObjectPropertyManufacturer:
  case kAudioObjectPropertyOwnedObjects:
  case kAudioPlugInPropertyDeviceList:
  case kAudioPlugInPropertyTranslateUIDToDevice:
  case kAudioPlugInPropertyResourceBundle:
    return true;
  default:
    return false;
  }
}

static bool OSVAHasDeviceProperty(AudioObjectID objectID,
                                  const AudioObjectPropertyAddress *address) {
  if (!OSVAIsMainElement(address)) {
    return false;
  }
  switch (address->mSelector) {
  case kAudioObjectPropertyCustomPropertyInfoList:
  case kOSVADiagnosticSnapshotProperty:
    return OSVAIsGlobal(address);
  case kAudioObjectPropertyOwnedObjects:
  case kAudioDevicePropertyStreams:
  case kAudioObjectPropertyControlList:
    return OSVAIsAnyDeviceScope(address);
  case kAudioDevicePropertyStreamConfiguration:
    return OSVAIsAnyDeviceScope(address);
  case kAudioDevicePropertyDeviceCanBeDefaultDevice:
  case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
  case kAudioDevicePropertyLatency:
  case kAudioDevicePropertySafetyOffset:
    return OSVAIsInput(address) || OSVAIsOutput(address);
  case kAudioDevicePropertyPreferredChannelLayout:
    return OSVAIsRoleScope(objectID, address);
  case kAudioDevicePropertyPreferredChannelsForStereo:
    return false;
  case kAudioObjectPropertyBaseClass:
  case kAudioObjectPropertyClass:
  case kAudioObjectPropertyOwner:
  case kAudioObjectPropertyName:
  case kAudioObjectPropertyManufacturer:
  case kAudioDevicePropertyDeviceUID:
  case kAudioDevicePropertyModelUID:
  case kAudioDevicePropertyTransportType:
  case kAudioDevicePropertyRelatedDevices:
  case kAudioDevicePropertyClockDomain:
  case kAudioDevicePropertyDeviceIsAlive:
  case kAudioDevicePropertyDeviceIsRunning:
  case kAudioDevicePropertyNominalSampleRate:
  case kAudioDevicePropertyAvailableNominalSampleRates:
  case kAudioDevicePropertyIsHidden:
  case kAudioDevicePropertyZeroTimeStampPeriod:
  case kAudioDevicePropertyClockAlgorithm:
  case kAudioDevicePropertyClockIsStable:
    return OSVAIsGlobal(address);
  default:
    return false;
  }
}

static bool OSVAHasStreamProperty(const AudioObjectPropertyAddress *address) {
  if (!OSVAIsMainElement(address) || !OSVAIsGlobal(address)) {
    return false;
  }
  switch (address->mSelector) {
  case kAudioObjectPropertyBaseClass:
  case kAudioObjectPropertyClass:
  case kAudioObjectPropertyOwner:
  case kAudioObjectPropertyName:
  case kAudioObjectPropertyOwnedObjects:
  case kAudioStreamPropertyIsActive:
  case kAudioStreamPropertyDirection:
  case kAudioStreamPropertyTerminalType:
  case kAudioStreamPropertyStartingChannel:
  case kAudioStreamPropertyLatency:
  case kAudioStreamPropertyVirtualFormat:
  case kAudioStreamPropertyPhysicalFormat:
  case kAudioStreamPropertyAvailableVirtualFormats:
  case kAudioStreamPropertyAvailablePhysicalFormats:
    return true;
  default:
    return false;
  }
}

static bool OSVAHasControlProperty(OSVAObjectKind kind,
                                   const AudioObjectPropertyAddress *address) {
  if (!OSVAIsMainElement(address) || !OSVAIsGlobal(address)) {
    return false;
  }
  switch (address->mSelector) {
  case kAudioObjectPropertyBaseClass:
  case kAudioObjectPropertyClass:
  case kAudioObjectPropertyOwner:
  case kAudioObjectPropertyOwnedObjects:
  case kAudioControlPropertyScope:
  case kAudioControlPropertyElement:
    return true;
  case kAudioLevelControlPropertyScalarValue:
  case kAudioLevelControlPropertyDecibelValue:
  case kAudioLevelControlPropertyDecibelRange:
  case kAudioLevelControlPropertyConvertScalarToDecibels:
  case kAudioLevelControlPropertyConvertDecibelsToScalar:
    return kind == kOSVAObjectVolume;
  case kAudioBooleanControlPropertyValue:
    return kind == kOSVAObjectMute;
  default:
    return false;
  }
}

static bool OSVAHasPropertyInternal(AudioObjectID objectID,
                                    const AudioObjectPropertyAddress *address) {
  switch (OSVAGetObjectKind(objectID)) {
  case kOSVAObjectPlugIn:
    return OSVAHasPlugInProperty(address);
  case kOSVAObjectDevice:
    return OSVAHasDeviceProperty(objectID, address);
  case kOSVAObjectStream:
    return OSVAHasStreamProperty(address);
  case kOSVAObjectVolume:
  case kOSVAObjectMute:
    return OSVAHasControlProperty(OSVAGetObjectKind(objectID), address);
  default:
    return false;
  }
}

static bool OSVALoadZeroTimestampDiagnostic(
    size_t index, OSVADiagnosticZeroTimestampSnapshot *snapshotOut) {
  const OSVAAtomicZeroTimestampDiagnostics *record =
      &gZeroTimestampDiagnostics[index];
  for (unsigned attempt = 0; attempt < OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT;
       ++attempt) {
    const uint64_t before =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (atomic_load_explicit(&record->active_publisher_count,
                             memory_order_acquire) != 0) {
      continue;
    }
    const uint64_t metadataBefore = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    if ((metadataBefore & UINT64_C(1)) != 0) {
      continue;
    }
    OSVADiagnosticZeroTimestampSnapshot snapshot = {
        .sequence = before,
        .metadata_sequence = metadataBefore,
        .metadata_dropped_update_count = atomic_load_explicit(
            &record->metadata_dropped_update_count, memory_order_relaxed),
        .epoch_mapping_unavailable_count = atomic_load_explicit(
            &record->epoch_mapping_unavailable_count, memory_order_relaxed),
        .call_count = atomic_load_explicit(&record->call_count,
                                           memory_order_relaxed),
        .successful_return_count = atomic_load_explicit(
            &record->successful_return_count, memory_order_relaxed),
        .fallback_return_count = atomic_load_explicit(
            &record->fallback_return_count, memory_order_relaxed),
        .failed_return_count = atomic_load_explicit(
            &record->failed_return_count, memory_order_relaxed),
        .last_call_host_ticks = atomic_load_explicit(
            &record->last_call_host_ticks, memory_order_relaxed),
        .last_sample_frame = atomic_load_explicit(
            &record->last_sample_frame, memory_order_relaxed),
        .last_host_ticks = atomic_load_explicit(&record->last_host_ticks,
                                                memory_order_relaxed),
        .last_seed = atomic_load_explicit(&record->last_seed,
                                          memory_order_relaxed),
        .last_seed_generation = atomic_load_explicit(
            &record->last_seed_generation, memory_order_relaxed),
        .last_core_lifecycle_sequence = atomic_load_explicit(
            &record->last_core_lifecycle_sequence, memory_order_relaxed),
        .last_call_core_lifecycle_sequence = atomic_load_explicit(
            &record->last_call_core_lifecycle_sequence,
            memory_order_relaxed),
        .last_client_id = atomic_load_explicit(&record->last_client_id,
                                               memory_order_relaxed),
        .last_status = atomic_load_explicit(&record->last_status,
                                            memory_order_relaxed),
        .flags = atomic_load_explicit(&record->flags, memory_order_relaxed),
    };
    atomic_thread_fence(memory_order_acquire);
    const uint64_t metadataAfter = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    const uint64_t activeAfter = atomic_load_explicit(
        &record->active_publisher_count, memory_order_acquire);
    const uint64_t after =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (before == after && metadataBefore == metadataAfter &&
        (metadataAfter & UINT64_C(1)) == 0 && activeAfter == 0) {
      *snapshotOut = snapshot;
      return true;
    }
  }
  return false;
}

static bool OSVALoadIODiagnostic(size_t index,
                                 OSVADiagnosticIOSnapshot *snapshotOut) {
  const OSVAAtomicIODiagnostics *record = &gIODiagnostics[index];
  for (unsigned attempt = 0; attempt < OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT;
       ++attempt) {
    const uint64_t before =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (atomic_load_explicit(&record->active_publisher_count,
                             memory_order_acquire) != 0) {
      continue;
    }
    const uint64_t metadataBefore = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    if ((metadataBefore & UINT64_C(1)) != 0) {
      continue;
    }
    OSVADiagnosticIOSnapshot snapshot = {
        .sequence = before,
        .metadata_sequence = metadataBefore,
        .metadata_dropped_update_count = atomic_load_explicit(
            &record->metadata_dropped_update_count, memory_order_relaxed),
        .operation_call_count = atomic_load_explicit(
            &record->operation_call_count, memory_order_relaxed),
        .valid_cycle_count = atomic_load_explicit(
            &record->valid_cycle_count, memory_order_relaxed),
        .invalid_cycle_count = atomic_load_explicit(
            &record->invalid_cycle_count, memory_order_relaxed),
        .lease_unavailable_count = atomic_load_explicit(
            &record->lease_unavailable_count, memory_order_relaxed),
        .epoch_mapping_unavailable_count = atomic_load_explicit(
            &record->epoch_mapping_unavailable_count, memory_order_relaxed),
        .core_ok_count = atomic_load_explicit(&record->core_ok_count,
                                              memory_order_relaxed),
        .core_retry_count = atomic_load_explicit(&record->core_retry_count,
                                                 memory_order_relaxed),
        .core_failure_count = atomic_load_explicit(
            &record->core_failure_count, memory_order_relaxed),
        .requested_frame_count = atomic_load_explicit(
            &record->requested_frame_count, memory_order_relaxed),
        .transferred_frame_count = atomic_load_explicit(
            &record->transferred_frame_count, memory_order_relaxed),
        .gap_frame_count = atomic_load_explicit(&record->gap_frame_count,
                                                memory_order_relaxed),
        .last_cycle_sample_frame = atomic_load_explicit(
            &record->last_cycle_sample_frame, memory_order_relaxed),
        .last_cycle_host_ticks = atomic_load_explicit(
            &record->last_cycle_host_ticks, memory_order_relaxed),
        .last_published_frame_seed = atomic_load_explicit(
            &record->last_published_frame_seed, memory_order_relaxed),
        .last_published_seed_generation = atomic_load_explicit(
            &record->last_published_seed_generation, memory_order_relaxed),
        .last_published_frame_session = atomic_load_explicit(
            &record->last_published_frame_session, memory_order_relaxed),
        .last_published_absolute_frame = atomic_load_explicit(
            &record->last_published_absolute_frame, memory_order_relaxed),
        .last_consumed_frame_seed = atomic_load_explicit(
            &record->last_consumed_frame_seed, memory_order_relaxed),
        .last_consumed_seed_generation = atomic_load_explicit(
            &record->last_consumed_seed_generation, memory_order_relaxed),
        .last_consumed_frame_session = atomic_load_explicit(
            &record->last_consumed_frame_session, memory_order_relaxed),
        .last_consumed_absolute_frame = atomic_load_explicit(
            &record->last_consumed_absolute_frame, memory_order_relaxed),
        .last_client_id = atomic_load_explicit(&record->last_client_id,
                                               memory_order_relaxed),
        .last_status = atomic_load_explicit(&record->last_status,
                                            memory_order_relaxed),
        .flags = atomic_load_explicit(&record->flags, memory_order_relaxed),
    };
    atomic_thread_fence(memory_order_acquire);
    const uint64_t metadataAfter = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    const uint64_t activeAfter = atomic_load_explicit(
        &record->active_publisher_count, memory_order_acquire);
    const uint64_t after =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (before == after && metadataBefore == metadataAfter &&
        (metadataAfter & UINT64_C(1)) == 0 && activeAfter == 0) {
      *snapshotOut = snapshot;
      return true;
    }
  }
  return false;
}

static bool OSVALoadIOWorkLoopDiagnostic(
    size_t index, OSVADiagnosticIOWorkLoopSnapshot *snapshotOut) {
  const OSVAAtomicIOWorkLoopDiagnostics *record =
      &gIOWorkLoopDiagnostics[index];
  for (unsigned attempt = 0; attempt < OSVA_DIAGNOSTIC_RECORD_ATTEMPT_LIMIT;
       ++attempt) {
    const uint64_t before =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (atomic_load_explicit(&record->active_publisher_count,
                             memory_order_acquire) != 0) {
      continue;
    }
    const uint64_t metadataBefore = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    if ((metadataBefore & UINT64_C(1)) != 0) {
      continue;
    }
    OSVADiagnosticIOWorkLoopSnapshot snapshot = {
        .sequence = before,
        .metadata_sequence = metadataBefore,
        .metadata_dropped_update_count = atomic_load_explicit(
            &record->metadata_dropped_update_count, memory_order_relaxed),
        .current_count = atomic_load_explicit(&record->current_count,
                                              memory_order_relaxed),
        .begin_count = atomic_load_explicit(&record->begin_count,
                                            memory_order_relaxed),
        .end_count = atomic_load_explicit(&record->end_count,
                                          memory_order_relaxed),
        .underflow_count = atomic_load_explicit(&record->underflow_count,
                                                memory_order_relaxed),
        .last_transition_host_ticks = atomic_load_explicit(
            &record->last_transition_host_ticks, memory_order_relaxed),
        .last_client_id = atomic_load_explicit(&record->last_client_id,
                                               memory_order_relaxed),
        .flags = atomic_load_explicit(&record->flags, memory_order_relaxed),
    };
    atomic_thread_fence(memory_order_acquire);
    const uint64_t metadataAfter = atomic_load_explicit(
        &record->metadata_sequence, memory_order_acquire);
    const uint64_t activeAfter = atomic_load_explicit(
        &record->active_publisher_count, memory_order_acquire);
    const uint64_t after =
        atomic_load_explicit(&record->sequence, memory_order_acquire);
    if (before == after && metadataBefore == metadataAfter &&
        (metadataAfter & UINT64_C(1)) == 0 && activeAfter == 0) {
      *snapshotOut = snapshot;
      return true;
    }
  }
  return false;
}

static bool OSVACopyDiagnosticSnapshot(OSVADiagnosticSnapshot *snapshotOut) {
  if (pthread_mutex_trylock(&gStateMutex) != 0) {
    return false;
  }
  if (!atomic_load_explicit(&gCoreInitialized, memory_order_acquire) ||
      pthread_mutex_trylock(&gCore.lifecycle_mutex) != 0) {
    (void)pthread_mutex_unlock(&gStateMutex);
    return false;
  }

  OSVADiagnosticSnapshot snapshot;
  memset(&snapshot, 0, sizeof(snapshot));
  snapshot.schema_version = kOSVADiagnosticSnapshotSchemaVersion;
  snapshot.struct_size = (UInt32)sizeof(snapshot);
  snapshot.driver_instance_generation =
      gDiagnosticLifecycle.driver_instance_generation;
  snapshot.driver_lifecycle_sequence =
      gDiagnosticLifecycle.lifecycle_sequence;
  snapshot.core_lifecycle_sequence = atomic_load_explicit(
      &gCore.lifecycle_sequence, memory_order_acquire);
  snapshot.host_ticks_per_second = gCore.host_ticks_per_second;
  snapshot.timeline_seed =
      atomic_load_explicit(&gCore.timeline_seed, memory_order_acquire);
  snapshot.current_seed_generation =
      gDiagnosticLifecycle.current_seed_generation;
  snapshot.anchor_host_ticks =
      atomic_load_explicit(&gCore.anchor_host_ticks, memory_order_relaxed);
  snapshot.last_issued_seed = gCore.last_issued_seed;
  snapshot.last_issued_session_id = gCore.last_issued_session_id;
  snapshot.active_client_count = atomic_load_explicit(
      &gCore.active_client_count, memory_order_relaxed);
  snapshot.visible_input_active_count = atomic_load_explicit(
      &gCore.visible_input_client_count, memory_order_relaxed);
  snapshot.hidden_writer_active_count = atomic_load_explicit(
      &gCore.hidden_writer_client_count, memory_order_relaxed);
  snapshot.driver_client_add_attempt_count =
      gDiagnosticLifecycle.driver_client_add_attempt_count;
  snapshot.driver_client_add_count =
      gDiagnosticLifecycle.driver_client_add_count;
  snapshot.driver_client_remove_attempt_count =
      gDiagnosticLifecycle.driver_client_remove_attempt_count;
  snapshot.driver_client_remove_count =
      gDiagnosticLifecycle.driver_client_remove_count;
  snapshot.global_start_attempt_count =
      gDiagnosticLifecycle.global_start_attempt_count;
  snapshot.global_start_transition_count =
      gDiagnosticLifecycle.global_start_transition_count;
  snapshot.global_stop_attempt_count =
      gDiagnosticLifecycle.global_stop_attempt_count;
  snapshot.global_stop_transition_count =
      gDiagnosticLifecycle.global_stop_transition_count;
  snapshot.seed_create_count = gDiagnosticLifecycle.seed_create_count;
  snapshot.seed_clear_count = gDiagnosticLifecycle.seed_clear_count;
  snapshot.last_seed_create_host_ticks =
      gDiagnosticLifecycle.last_seed_create_host_ticks;
  snapshot.last_seed_clear_host_ticks =
      gDiagnosticLifecycle.last_seed_clear_host_ticks;
  snapshot.last_cleared_seed = gDiagnosticLifecycle.last_cleared_seed;
  snapshot.last_cleared_seed_generation =
      gDiagnosticLifecycle.last_cleared_seed_generation;
  snapshot.last_cleared_anchor_host_ticks =
      gDiagnosticLifecycle.last_cleared_anchor_host_ticks;
  snapshot.client_slot_capacity = kOSVADiagnosticClientSlotCapacity;
  snapshot.last_driver_transition =
      gDiagnosticLifecycle.last_driver_transition;
  snapshot.last_core_transition = gDiagnosticLifecycle.last_core_transition;

  uint64_t derivedVisibleCoreCount = 0;
  uint64_t derivedWriterCoreCount = 0;
  bool activeSlotsUseCurrentSeed = true;
  for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    const OSVAClientSlot *slot = &gCoreClients[index];
    const uint64_t sessionID =
        atomic_load_explicit(&slot->session_id, memory_order_acquire);
    OSVADiagnosticCoreClientSlotSnapshot *slotSnapshot =
        &snapshot.core_client_slots[index];
    slotSnapshot->session_id = sessionID;
    slotSnapshot->client_id =
        atomic_load_explicit(&slot->client_id, memory_order_relaxed);
    slotSnapshot->timeline_seed =
        atomic_load_explicit(&slot->timeline_seed, memory_order_relaxed);
    slotSnapshot->endpoint_role =
        atomic_load_explicit(&slot->endpoint, memory_order_relaxed);
    if (sessionID == 0) {
      continue;
    }
    snapshot.core_active_slot_count += 1;
    snapshot.core_active_slot_bitmap |= UINT64_C(1) << index;
    if (slotSnapshot->endpoint_role == OSVA_ENDPOINT_VISIBLE_INPUT) {
      derivedVisibleCoreCount += 1;
    } else if (slotSnapshot->endpoint_role == OSVA_ENDPOINT_HIDDEN_WRITER) {
      derivedWriterCoreCount += 1;
    }
    if (slotSnapshot->timeline_seed != snapshot.timeline_seed) {
      activeSlotsUseCurrentSeed = false;
    }
  }

  bool driverStartsMatchCoreSlots = true;
  uint64_t referencedCoreSlotBitmap = 0;
  for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    const OSVADriverClient *client = &gDriverClients[index];
    OSVADiagnosticDriverClientSlotSnapshot *slotSnapshot =
        &snapshot.driver_client_slots[index];
    slotSnapshot->generation = client->generation;
    slotSnapshot->registration_host_ticks =
        client->registration_host_ticks;
    slotSnapshot->start_host_ticks = client->start_host_ticks;
    slotSnapshot->last_transition_host_ticks =
        client->last_transition_host_ticks;
    slotSnapshot->lease_session_id = client->lease.session_id;
    slotSnapshot->lease_timeline_seed = client->lease.timeline_seed;
    slotSnapshot->device_object_id = client->device_object_id;
    slotSnapshot->client_id = client->client_id;
    slotSnapshot->process_id = (SInt32)client->process_id;
    slotSnapshot->endpoint_role =
        client->registered
            ? (OSVAIsVisibleDevice(client->device_object_id)
                   ? kOSVADiagnosticEndpointVisibleInput
                   : kOSVADiagnosticEndpointHiddenWriter)
            : kOSVADiagnosticEndpointNone;
    slotSnapshot->core_client_slot =
        client->started ? client->lease.client_slot : OSVA_INVALID_CLIENT_SLOT;
    slotSnapshot->io_start_depth = client->io_start_depth;
    if (!client->registered) {
      continue;
    }
    slotSnapshot->flags |= kOSVADiagnosticDriverSlotRegistered;
    snapshot.driver_registered_count += 1;
    snapshot.driver_registered_slot_bitmap |= UINT64_C(1) << index;
    if (OSVAIsVisibleDevice(client->device_object_id)) {
      snapshot.visible_driver_registered_count += 1;
    } else {
      snapshot.hidden_driver_registered_count += 1;
    }
    if (!client->started) {
      continue;
    }
    slotSnapshot->flags |= kOSVADiagnosticDriverSlotStarted |
                           kOSVADiagnosticDriverSlotLeaseValid;
    snapshot.driver_started_count += 1;
    snapshot.driver_started_slot_bitmap |= UINT64_C(1) << index;
    if (OSVAIsVisibleDevice(client->device_object_id)) {
      snapshot.visible_driver_started_count += 1;
    } else {
      snapshot.hidden_driver_started_count += 1;
    }
    if (client->lease.client_slot >= OSVA_DRIVER_CLIENT_SLOT_COUNT) {
      driverStartsMatchCoreSlots = false;
      continue;
    }
    const OSVADiagnosticCoreClientSlotSnapshot *coreSlot =
        &snapshot.core_client_slots[client->lease.client_slot];
    const uint64_t coreSlotBit = UINT64_C(1) << client->lease.client_slot;
    if ((referencedCoreSlotBitmap & coreSlotBit) != 0 ||
        coreSlot->session_id != client->lease.session_id ||
        coreSlot->client_id != client->lease.client_id ||
        coreSlot->timeline_seed != client->lease.timeline_seed ||
        coreSlot->endpoint_role != (UInt32)client->lease.endpoint) {
      driverStartsMatchCoreSlots = false;
    }
    referencedCoreSlotBitmap |= coreSlotBit;
  }
  driverStartsMatchCoreSlots =
      driverStartsMatchCoreSlots &&
      referencedCoreSlotBitmap == snapshot.core_active_slot_bitmap;

  bool recordsAvailable = true;
  for (size_t index = 0; index < OSVA_DIAGNOSTIC_ENDPOINT_COUNT; ++index) {
    recordsAvailable =
        recordsAvailable &&
        OSVALoadZeroTimestampDiagnostic(index,
                                        &snapshot.zero_timestamp[index]) &&
        OSVALoadIODiagnostic(index, &snapshot.io[index]) &&
        OSVALoadIOWorkLoopDiagnostic(index, &snapshot.io_work_loop[index]);
  }
  if (!recordsAvailable) {
    (void)pthread_mutex_unlock(&gCore.lifecycle_mutex);
    (void)pthread_mutex_unlock(&gStateMutex);
    return false;
  }
  if (gDiagnosticLifecycle.snapshot_observation_sequence == UINT64_MAX) {
    (void)pthread_mutex_unlock(&gCore.lifecycle_mutex);
    (void)pthread_mutex_unlock(&gStateMutex);
    return false;
  }
  gDiagnosticLifecycle.snapshot_observation_sequence += 1;
  snapshot.snapshot_sequence =
      gDiagnosticLifecycle.snapshot_observation_sequence;
  snapshot.captured_host_ticks = mach_absolute_time();

  uint64_t flags = kOSVADiagnosticSnapshotCoreInitialized;
  if (snapshot.timeline_seed != 0) {
    flags |= kOSVADiagnosticSnapshotTimelineActive;
  }
  if (snapshot.active_client_count == snapshot.core_active_slot_count) {
    flags |= kOSVADiagnosticInvariantGlobalMatchesCoreSlots;
  }
  if (snapshot.visible_input_active_count == derivedVisibleCoreCount &&
      snapshot.hidden_writer_active_count == derivedWriterCoreCount) {
    flags |= kOSVADiagnosticInvariantEndpointsMatchCoreSlots;
  }
  if (driverStartsMatchCoreSlots) {
    flags |= kOSVADiagnosticInvariantDriverStartsMatchCoreSlots;
  }
  if (snapshot.active_client_count != 0 ||
      (snapshot.timeline_seed == 0 && snapshot.anchor_host_ticks == 0 &&
       snapshot.current_seed_generation == 0)) {
    flags |= kOSVADiagnosticInvariantIdleImpliesClockCleared;
  }
  if (snapshot.active_client_count == 0 ||
      (snapshot.timeline_seed != 0 && snapshot.anchor_host_ticks != 0 &&
       snapshot.current_seed_generation != 0)) {
    flags |= kOSVADiagnosticInvariantActiveImpliesClockValid;
  }
  if (snapshot.core_active_slot_count <= OSVA_DRIVER_CLIENT_SLOT_COUNT &&
      snapshot.driver_registered_count <= OSVA_DRIVER_CLIENT_SLOT_COUNT &&
      snapshot.driver_started_count <= OSVA_DRIVER_CLIENT_SLOT_COUNT) {
    flags |= kOSVADiagnosticInvariantSlotCountsWithinCapacity;
  }
  if (snapshot.active_client_count != 0 ||
      snapshot.global_start_transition_count ==
          snapshot.global_stop_transition_count) {
    flags |= kOSVADiagnosticInvariantStartStopBalancedAtIdle;
  }
  if (snapshot.active_client_count != 0 ||
      snapshot.seed_create_count == snapshot.seed_clear_count) {
    flags |= kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle;
  }
  const uint64_t lastPublishedSeed =
      snapshot.io[OSVADiagnosticEndpointIndex(OSVA_ENDPOINT_HIDDEN_WRITER)]
          .last_published_frame_seed;
  const uint64_t lastPublishedGeneration =
      snapshot.io[OSVADiagnosticEndpointIndex(OSVA_ENDPOINT_HIDDEN_WRITER)]
          .last_published_seed_generation;
  const uint64_t lastConsumedSeed =
      snapshot.io[OSVADiagnosticEndpointIndex(OSVA_ENDPOINT_VISIBLE_INPUT)]
          .last_consumed_frame_seed;
  const uint64_t lastConsumedGeneration =
      snapshot.io[OSVADiagnosticEndpointIndex(OSVA_ENDPOINT_VISIBLE_INPUT)]
          .last_consumed_seed_generation;
  const bool currentEpochIdentityMatches =
      snapshot.timeline_seed == 0 ||
      snapshot.timeline_seed == snapshot.current_seed_generation;
  const bool publishedRecordMatches =
      snapshot.timeline_seed == 0 ||
      ((lastPublishedSeed == snapshot.timeline_seed) ==
       (lastPublishedGeneration == snapshot.current_seed_generation));
  const bool consumedRecordMatches =
      snapshot.timeline_seed == 0 ||
      ((lastConsumedSeed == snapshot.timeline_seed) ==
       (lastConsumedGeneration == snapshot.current_seed_generation));
  if (currentEpochIdentityMatches && publishedRecordMatches &&
      consumedRecordMatches) {
    flags |= kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed;
  }
  if (activeSlotsUseCurrentSeed) {
    flags |=
        kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration;
  }
  snapshot.invariant_flags = flags;

  (void)pthread_mutex_unlock(&gCore.lifecycle_mutex);
  (void)pthread_mutex_unlock(&gStateMutex);
  *snapshotOut = snapshot;
  return true;
}

static size_t OSVADeviceRoleObjectCount(AudioObjectID objectID,
                                        AudioObjectPropertyScope scope) {
  if (scope == kAudioObjectPropertyScopeGlobal ||
      (OSVAIsVisibleDevice(objectID) &&
       scope == kAudioObjectPropertyScopeInput) ||
      (OSVAIsHiddenDevice(objectID) &&
       scope == kAudioObjectPropertyScopeOutput)) {
    return 3;
  }
  return 0;
}

static size_t OSVADeviceRoleStreamCount(AudioObjectID objectID,
                                        AudioObjectPropertyScope scope) {
  return OSVADeviceRoleObjectCount(objectID, scope) == 0 ? 0 : 1;
}

static size_t OSVADeviceRoleControlCount(AudioObjectID objectID,
                                         AudioObjectPropertyScope scope) {
  return OSVADeviceRoleObjectCount(objectID, scope) == 0 ? 0 : 2;
}

static UInt32 OSVAPropertyDataSize(AudioObjectID objectID,
                                   const AudioObjectPropertyAddress *address) {
  switch (address->mSelector) {
  case kAudioObjectPropertyCustomPropertyInfoList:
    return (UInt32)sizeof(AudioServerPlugInCustomPropertyInfo);
  case kOSVADiagnosticSnapshotProperty:
    return (UInt32)sizeof(CFPropertyListRef);
  case kAudioObjectPropertyBaseClass:
  case kAudioObjectPropertyClass:
    return (UInt32)sizeof(AudioClassID);
  case kAudioObjectPropertyOwner:
  case kAudioPlugInPropertyTranslateUIDToDevice:
    return (UInt32)sizeof(AudioObjectID);
  case kAudioObjectPropertyManufacturer:
  case kAudioObjectPropertyName:
  case kAudioPlugInPropertyResourceBundle:
  case kAudioDevicePropertyDeviceUID:
  case kAudioDevicePropertyModelUID:
    return (UInt32)sizeof(CFStringRef);
  case kAudioObjectPropertyOwnedObjects:
    if (objectID == kOSVAObjectIDPlugIn) {
      return 2U * (UInt32)sizeof(AudioObjectID);
    }
    if (OSVAIsDevice(objectID)) {
      return (UInt32)(OSVADeviceRoleObjectCount(objectID, address->mScope) *
                      sizeof(AudioObjectID));
    }
    return 0;
  case kAudioPlugInPropertyDeviceList:
  case kAudioDevicePropertyRelatedDevices:
    return 2U * (UInt32)sizeof(AudioObjectID);
  case kAudioDevicePropertyStreams:
    return (UInt32)(OSVADeviceRoleStreamCount(objectID, address->mScope) *
                    sizeof(AudioObjectID));
  case kAudioObjectPropertyControlList:
    return (UInt32)(OSVADeviceRoleControlCount(objectID, address->mScope) *
                    sizeof(AudioObjectID));
  case kAudioDevicePropertyStreamConfiguration: {
    const UInt32 headerSize = (UInt32)offsetof(AudioBufferList, mBuffers);
    return OSVADeviceRoleStreamCount(objectID, address->mScope) == 1U
               ? headerSize + (UInt32)sizeof(AudioBuffer)
               : headerSize;
  }
  case kAudioDevicePropertyNominalSampleRate:
    return (UInt32)sizeof(Float64);
  case kAudioDevicePropertyAvailableNominalSampleRates:
  case kAudioLevelControlPropertyDecibelRange:
    return (UInt32)sizeof(AudioValueRange);
  case kAudioDevicePropertyPreferredChannelLayout:
    return (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
  case kAudioStreamPropertyVirtualFormat:
  case kAudioStreamPropertyPhysicalFormat:
    return (UInt32)sizeof(AudioStreamBasicDescription);
  case kAudioStreamPropertyAvailableVirtualFormats:
  case kAudioStreamPropertyAvailablePhysicalFormats:
    return (UInt32)sizeof(AudioStreamRangedDescription);
  case kAudioLevelControlPropertyScalarValue:
  case kAudioLevelControlPropertyDecibelValue:
  case kAudioLevelControlPropertyConvertScalarToDecibels:
  case kAudioLevelControlPropertyConvertDecibelsToScalar:
    return (UInt32)sizeof(Float32);
  default:
    return (UInt32)sizeof(UInt32);
  }
}

void *OpensteamerVirtualMicrophone_Create(CFAllocatorRef allocator,
                                          CFUUIDRef requestedTypeUUID) {
  (void)allocator;
  if (requestedTypeUUID != NULL &&
      CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
    return gDriverRef;
  }
  return NULL;
}

static bool OSVAIsValidDriver(AudioServerPlugInDriverRef driver) {
  return driver == gDriverRef;
}

static HRESULT OSVAQueryInterface(void *driver, REFIID uuid,
                                  LPVOID *outInterface) {
  if (driver != gDriverRef) {
    return kAudioHardwareBadObjectError;
  }
  if (outInterface == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  *outInterface = NULL;
  CFUUIDRef requestedUUID =
      CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid);
  if (requestedUUID == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  bool supported =
      CFEqual(requestedUUID, IUnknownUUID) ||
      CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID);
  CFRelease(requestedUUID);
  if (!supported) {
    return E_NOINTERFACE;
  }
  (void)OSVAAddRef(driver);
  *outInterface = gDriverRef;
  return S_OK;
}

static ULONG OSVAAddRef(void *driver) {
  if (driver != gDriverRef) {
    return 0;
  }
  ULONG previous = atomic_load_explicit(&gReferenceCount, memory_order_relaxed);
  while (previous < UINT32_MAX &&
         !atomic_compare_exchange_weak_explicit(
             &gReferenceCount, &previous, previous + 1, memory_order_relaxed,
             memory_order_relaxed)) {
  }
  return previous == UINT32_MAX ? UINT32_MAX : previous + 1;
}

static ULONG OSVARelease(void *driver) {
  if (driver != gDriverRef) {
    return 0;
  }
  ULONG previous = atomic_load_explicit(&gReferenceCount, memory_order_relaxed);
  while (previous > 0 && !atomic_compare_exchange_weak_explicit(
                             &gReferenceCount, &previous, previous - 1,
                             memory_order_relaxed, memory_order_relaxed)) {
  }
  return previous == 0 ? 0 : previous - 1;
}

static Boolean OSVAHasProperty(AudioServerPlugInDriverRef driver,
                               AudioObjectID objectID, pid_t clientProcessID,
                               const AudioObjectPropertyAddress *address) {
  (void)clientProcessID;
  if (!OSVAIsValidDriver(driver) || address == NULL) {
    return false;
  }
  return OSVAHasPropertyInternal(objectID, address);
}

static OSStatus
OSVAIsPropertySettable(AudioServerPlugInDriverRef driver,
                       AudioObjectID objectID, pid_t clientProcessID,
                       const AudioObjectPropertyAddress *address,
                       Boolean *outIsSettable) {
  (void)clientProcessID;
  if (!OSVAIsValidDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  if (address == NULL || outIsSettable == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (OSVAGetObjectKind(objectID) == kOSVAObjectInvalid) {
    return kAudioHardwareBadObjectError;
  }
  if (!OSVAHasPropertyInternal(objectID, address)) {
    return kAudioHardwareUnknownPropertyError;
  }
  *outIsSettable = false;
  return noErr;
}

static OSStatus OSVAValidateUIDQualifier(UInt32 qualifierDataSize,
                                         const void *qualifierData) {
  if (qualifierDataSize != sizeof(CFStringRef) || qualifierData == NULL ||
      *(const CFStringRef *)qualifierData == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }
  if (CFGetTypeID(*(const CFStringRef *)qualifierData) != CFStringGetTypeID()) {
    return kAudioHardwareBadPropertySizeError;
  }
  return noErr;
}

static OSStatus OSVAGetPropertyDataSize(
    AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
    UInt32 qualifierDataSize, const void *qualifierData, UInt32 *outDataSize) {
  (void)clientProcessID;
  if (!OSVAIsValidDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  if (address == NULL || outDataSize == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (OSVAGetObjectKind(objectID) == kOSVAObjectInvalid) {
    return kAudioHardwareBadObjectError;
  }
  if (!OSVAHasPropertyInternal(objectID, address)) {
    return kAudioHardwareUnknownPropertyError;
  }
  if (address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
    OSStatus status =
        OSVAValidateUIDQualifier(qualifierDataSize, qualifierData);
    if (status != noErr) {
      return status;
    }
  }
  *outDataSize = OSVAPropertyDataSize(objectID, address);
  return noErr;
}

static OSStatus OSVAWriteScalar(const void *value, UInt32 valueSize,
                                UInt32 dataSize, UInt32 *outDataSize,
                                void *outData) {
  if (dataSize < valueSize) {
    return kAudioHardwareBadPropertySizeError;
  }
  memcpy(outData, value, valueSize);
  *outDataSize = valueSize;
  return noErr;
}

static OSStatus OSVAWriteObjectList(const AudioObjectID *values,
                                    size_t valueCount, UInt32 dataSize,
                                    UInt32 *outDataSize, void *outData) {
  size_t capacity = dataSize / sizeof(AudioObjectID);
  size_t copyCount = capacity < valueCount ? capacity : valueCount;
  if (copyCount > 0) {
    memcpy(outData, values, copyCount * sizeof(AudioObjectID));
  }
  *outDataSize = (UInt32)(copyCount * sizeof(AudioObjectID));
  return noErr;
}

static AudioClassID OSVABaseClassForObject(AudioObjectID objectID) {
  switch (OSVAGetObjectKind(objectID)) {
  case kOSVAObjectVolume:
    return kAudioLevelControlClassID;
  case kOSVAObjectMute:
    return kAudioBooleanControlClassID;
  default:
    return kAudioObjectClassID;
  }
}

static AudioClassID OSVAClassForObject(AudioObjectID objectID) {
  switch (OSVAGetObjectKind(objectID)) {
  case kOSVAObjectPlugIn:
    return kAudioPlugInClassID;
  case kOSVAObjectDevice:
    return kAudioDeviceClassID;
  case kOSVAObjectStream:
    return kAudioStreamClassID;
  case kOSVAObjectVolume:
    return kAudioVolumeControlClassID;
  case kOSVAObjectMute:
    return kAudioMuteControlClassID;
  default:
    return kAudioObjectClassID;
  }
}

static CFStringRef OSVANameForObject(AudioObjectID objectID) {
  switch (objectID) {
  case kOSVAObjectIDVisibleInputDevice:
    return CFSTR("opensteamer Virtual Microphone");
  case kOSVAObjectIDVisibleInputStream:
    return CFSTR("opensteamer Virtual Microphone Input Stream");
  case kOSVAObjectIDHiddenWriterDevice:
    return CFSTR("opensteamer Virtual Microphone Writer");
  case kOSVAObjectIDHiddenWriterStream:
    return CFSTR("opensteamer Virtual Microphone Writer Output Stream");
  default:
    return CFSTR("");
  }
}

static AudioStreamBasicDescription OSVAMonoFormat(void) {
  AudioStreamBasicDescription format = {
      .mSampleRate = 48000.0,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                      kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 4,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 4,
      .mChannelsPerFrame = 1,
      .mBitsPerChannel = 32,
      .mReserved = 0,
  };
  return format;
}

static OSStatus OSVAWriteOwnedObjects(AudioObjectID objectID,
                                      const AudioObjectPropertyAddress *address,
                                      UInt32 dataSize, UInt32 *outDataSize,
                                      void *outData) {
  static const AudioObjectID devices[] = {
      kOSVAObjectIDVisibleInputDevice,
      kOSVAObjectIDHiddenWriterDevice,
  };
  static const AudioObjectID visibleObjects[] = {
      kOSVAObjectIDVisibleInputStream,
      kOSVAObjectIDVisibleInputVolume,
      kOSVAObjectIDVisibleInputMute,
  };
  static const AudioObjectID hiddenObjects[] = {
      kOSVAObjectIDHiddenWriterStream,
      kOSVAObjectIDHiddenWriterVolume,
      kOSVAObjectIDHiddenWriterMute,
  };
  if (objectID == kOSVAObjectIDPlugIn) {
    return OSVAWriteObjectList(devices, 2, dataSize, outDataSize, outData);
  }
  if (OSVAIsVisibleDevice(objectID) &&
      OSVADeviceRoleObjectCount(objectID, address->mScope) != 0) {
    return OSVAWriteObjectList(visibleObjects, 3, dataSize, outDataSize,
                               outData);
  }
  if (OSVAIsHiddenDevice(objectID) &&
      OSVADeviceRoleObjectCount(objectID, address->mScope) != 0) {
    return OSVAWriteObjectList(hiddenObjects, 3, dataSize, outDataSize,
                               outData);
  }
  return OSVAWriteObjectList(NULL, 0, dataSize, outDataSize, outData);
}

static OSStatus OSVAWriteStreams(AudioObjectID objectID,
                                 const AudioObjectPropertyAddress *address,
                                 UInt32 dataSize, UInt32 *outDataSize,
                                 void *outData) {
  AudioObjectID stream = OSVAIsVisibleDevice(objectID)
                             ? kOSVAObjectIDVisibleInputStream
                             : kOSVAObjectIDHiddenWriterStream;
  size_t count = OSVADeviceRoleStreamCount(objectID, address->mScope);
  return OSVAWriteObjectList(&stream, count, dataSize, outDataSize, outData);
}

static OSStatus OSVAWriteControls(AudioObjectID objectID,
                                  const AudioObjectPropertyAddress *address,
                                  UInt32 dataSize, UInt32 *outDataSize,
                                  void *outData) {
  AudioObjectID controls[2] = {
      OSVAIsVisibleDevice(objectID) ? kOSVAObjectIDVisibleInputVolume
                                    : kOSVAObjectIDHiddenWriterVolume,
      OSVAIsVisibleDevice(objectID) ? kOSVAObjectIDVisibleInputMute
                                    : kOSVAObjectIDHiddenWriterMute,
  };
  size_t count = OSVADeviceRoleControlCount(objectID, address->mScope);
  return OSVAWriteObjectList(controls, count, dataSize, outDataSize, outData);
}

static OSStatus
OSVAWriteStreamConfiguration(AudioObjectID objectID,
                             const AudioObjectPropertyAddress *address,
                             UInt32 dataSize, UInt32 *outDataSize,
                             void *outData) {
  const UInt32 headerSize = (UInt32)offsetof(AudioBufferList, mBuffers);
  const UInt32 bufferCount =
      OSVADeviceRoleStreamCount(objectID, address->mScope) == 1U ? 1U : 0U;
  const UInt32 requiredSize =
      headerSize + bufferCount * (UInt32)sizeof(AudioBuffer);
  if (dataSize < requiredSize) {
    return kAudioHardwareBadPropertySizeError;
  }

  memset(outData, 0, requiredSize);
  memcpy(outData, &bufferCount, sizeof(bufferCount));
  if (bufferCount == 1U) {
    const AudioBuffer buffer = {
        .mNumberChannels = 1U,
        .mDataByteSize = 0U,
        .mData = NULL,
    };
    memcpy((uint8_t *)outData + headerSize, &buffer, sizeof(buffer));
  }
  *outDataSize = requiredSize;
  return noErr;
}

static bool OSVADeviceIsRunning(AudioObjectID deviceObjectID) {
  OSVACoreSnapshot snapshot;
  if (!gCoreInitialized ||
      OSVACoreGetSnapshot(&gCore, &snapshot) != OSVA_STATUS_OK) {
    return false;
  }
  return OSVAIsVisibleDevice(deviceObjectID)
             ? snapshot.visible_input_client_count > 0
             : snapshot.hidden_writer_client_count > 0;
}

static OSStatus OSVAGetPropertyData(AudioServerPlugInDriverRef driver,
                                    AudioObjectID objectID,
                                    pid_t clientProcessID,
                                    const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize,
                                    const void *qualifierData, UInt32 dataSize,
                                    UInt32 *outDataSize, void *outData) {
  (void)clientProcessID;
  if (!OSVAIsValidDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  if (address == NULL || outDataSize == NULL || outData == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (OSVAGetObjectKind(objectID) == kOSVAObjectInvalid) {
    return kAudioHardwareBadObjectError;
  }
  if (!OSVAHasPropertyInternal(objectID, address)) {
    return kAudioHardwareUnknownPropertyError;
  }
  if (address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
    OSStatus status =
        OSVAValidateUIDQualifier(qualifierDataSize, qualifierData);
    if (status != noErr) {
      return status;
    }
  }
  *outDataSize = 0;

  switch (address->mSelector) {
  case kAudioObjectPropertyCustomPropertyInfoList: {
    AudioServerPlugInCustomPropertyInfo value = {
        .mSelector = kOSVADiagnosticSnapshotProperty,
        .mPropertyDataType =
            kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
        .mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone,
    };
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kOSVADiagnosticSnapshotProperty: {
    if (dataSize < sizeof(CFPropertyListRef)) {
      return kAudioHardwareBadPropertySizeError;
    }
    OSVADiagnosticSnapshot snapshot;
    if (!OSVACopyDiagnosticSnapshot(&snapshot)) {
      return kOSVADiagnosticSnapshotUnavailableError;
    }
    /*
     * AudioServerPlugIn custom-property IPC only marshals CFString or
     * CFPropertyList values. The coherent POD capture above is stack-only and
     * releases both lifecycle locks first; this immutable CFData creation is
     * the sole transport allocation and is never reached from an RT callback.
     */
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&snapshot,
                                  (CFIndex)sizeof(snapshot));
    if (data == NULL) {
      return kOSVADiagnosticSnapshotUnavailableError;
    }
    CFPropertyListRef value = data;
    memcpy(outData, &value, sizeof(value));
    *outDataSize = (UInt32)sizeof(value);
    return noErr;
  }
  case kAudioObjectPropertyBaseClass: {
    AudioClassID value = OSVABaseClassForObject(objectID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioObjectPropertyClass: {
    AudioClassID value = OSVAClassForObject(objectID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioObjectPropertyOwner: {
    AudioObjectID value = objectID == kOSVAObjectIDPlugIn
                              ? kAudioObjectUnknown
                              : OSVAOwnerForObject(objectID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioObjectPropertyManufacturer: {
    CFStringRef value = CFSTR("opensteamer");
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioObjectPropertyName: {
    CFStringRef value = OSVANameForObject(objectID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioObjectPropertyOwnedObjects:
    return OSVAWriteOwnedObjects(objectID, address, dataSize, outDataSize,
                                 outData);
  case kAudioPlugInPropertyDeviceList: {
    static const AudioObjectID devices[] = {
        kOSVAObjectIDVisibleInputDevice,
        kOSVAObjectIDHiddenWriterDevice,
    };
    return OSVAWriteObjectList(devices, 2, dataSize, outDataSize, outData);
  }
  case kAudioPlugInPropertyTranslateUIDToDevice: {
    CFStringRef uid = *(const CFStringRef *)qualifierData;
    AudioObjectID value = kAudioObjectUnknown;
    if (CFEqual(uid, CFSTR(OSVA_VISIBLE_INPUT_DEVICE_UID))) {
      value = kOSVAObjectIDVisibleInputDevice;
    } else if (CFEqual(uid, CFSTR(OSVA_HIDDEN_WRITER_DEVICE_UID))) {
      value = kOSVAObjectIDHiddenWriterDevice;
    }
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioPlugInPropertyResourceBundle: {
    CFStringRef value = CFSTR("");
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyDeviceUID: {
    CFStringRef value = OSVAIsVisibleDevice(objectID)
                            ? CFSTR(OSVA_VISIBLE_INPUT_DEVICE_UID)
                            : CFSTR(OSVA_HIDDEN_WRITER_DEVICE_UID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyModelUID: {
    CFStringRef value = CFSTR(OSVA_DEVICE_MODEL_UID);
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyTransportType: {
    UInt32 value = kAudioDeviceTransportTypeVirtual;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyRelatedDevices: {
    static const AudioObjectID devices[] = {
        kOSVAObjectIDVisibleInputDevice,
        kOSVAObjectIDHiddenWriterDevice,
    };
    return OSVAWriteObjectList(devices, 2, dataSize, outDataSize, outData);
  }
  case kAudioDevicePropertyClockDomain: {
    UInt32 value = kOSVAClockDomain;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyDeviceIsAlive:
  case kAudioDevicePropertyClockIsStable: {
    UInt32 value = 1;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyDeviceIsRunning: {
    UInt32 value = OSVADeviceIsRunning(objectID) ? 1U : 0U;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyDeviceCanBeDefaultDevice: {
    UInt32 value =
        OSVAIsVisibleDevice(objectID) && OSVAIsInput(address) ? 1U : 0U;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
  case kAudioDevicePropertyLatency:
  case kAudioDevicePropertySafetyOffset: {
    UInt32 value = 0;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyStreams:
    return OSVAWriteStreams(objectID, address, dataSize, outDataSize, outData);
  case kAudioObjectPropertyControlList:
    return OSVAWriteControls(objectID, address, dataSize, outDataSize, outData);
  case kAudioDevicePropertyStreamConfiguration:
    return OSVAWriteStreamConfiguration(objectID, address, dataSize,
                                        outDataSize, outData);
  case kAudioDevicePropertyNominalSampleRate: {
    Float64 value = 48000.0;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyAvailableNominalSampleRates: {
    AudioValueRange value = {.mMinimum = 48000.0, .mMaximum = 48000.0};
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyIsHidden: {
    UInt32 value = OSVAIsHiddenDevice(objectID) ? 1U : 0U;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyZeroTimeStampPeriod: {
    UInt32 value = kOSVAZeroTimeStampPeriodFrames;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyClockAlgorithm: {
    UInt32 value = kAudioDeviceClockAlgorithmRaw;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioDevicePropertyPreferredChannelLayout: {
    UInt32 required =
        (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
    if (dataSize < required) {
      return kAudioHardwareBadPropertySizeError;
    }
    AudioChannelLayout *layout = outData;
    memset(layout, 0, required);
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    *outDataSize = required;
    return noErr;
  }
  case kAudioStreamPropertyIsActive: {
    UInt32 value = 1;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioStreamPropertyDirection: {
    UInt32 value = objectID == kOSVAObjectIDVisibleInputStream ? 1U : 0U;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioStreamPropertyTerminalType: {
    UInt32 value = objectID == kOSVAObjectIDVisibleInputStream
                       ? kAudioStreamTerminalTypeMicrophone
                       : kAudioStreamTerminalTypeSpeaker;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioStreamPropertyStartingChannel: {
    UInt32 value = 1;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioStreamPropertyVirtualFormat:
  case kAudioStreamPropertyPhysicalFormat: {
    AudioStreamBasicDescription value = OSVAMonoFormat();
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioStreamPropertyAvailableVirtualFormats:
  case kAudioStreamPropertyAvailablePhysicalFormats: {
    AudioStreamRangedDescription value = {
        .mFormat = OSVAMonoFormat(),
        .mSampleRateRange = {.mMinimum = 48000.0, .mMaximum = 48000.0},
    };
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioControlPropertyScope: {
    UInt32 value = OSVAIsVisibleObject(objectID)
                       ? kAudioObjectPropertyScopeInput
                       : kAudioObjectPropertyScopeOutput;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioControlPropertyElement: {
    UInt32 value = kAudioObjectPropertyElementMain;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioLevelControlPropertyScalarValue:
  case kAudioLevelControlPropertyConvertDecibelsToScalar: {
    Float32 value = 1.0F;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioLevelControlPropertyDecibelValue:
  case kAudioLevelControlPropertyConvertScalarToDecibels: {
    Float32 value = 0.0F;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioLevelControlPropertyDecibelRange: {
    AudioValueRange value = {.mMinimum = 0.0, .mMaximum = 0.0};
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  case kAudioBooleanControlPropertyValue: {
    UInt32 value = 0;
    return OSVAWriteScalar(&value, sizeof(value), dataSize, outDataSize,
                           outData);
  }
  default:
    return kAudioHardwareUnknownPropertyError;
  }
}

static OSStatus OSVASetPropertyData(AudioServerPlugInDriverRef driver,
                                    AudioObjectID objectID,
                                    pid_t clientProcessID,
                                    const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize,
                                    const void *qualifierData, UInt32 dataSize,
                                    const void *data) {
  (void)clientProcessID;
  (void)qualifierDataSize;
  (void)qualifierData;
  (void)dataSize;
  (void)data;
  if (!OSVAIsValidDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  if (address == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (OSVAGetObjectKind(objectID) == kOSVAObjectInvalid) {
    return kAudioHardwareBadObjectError;
  }
  return OSVAHasPropertyInternal(objectID, address)
             ? kAudioHardwareIllegalOperationError
             : kAudioHardwareUnknownPropertyError;
}

static OSStatus OSVACreateDevice(AudioServerPlugInDriverRef driver,
                                 CFDictionaryRef description,
                                 const AudioServerPlugInClientInfo *clientInfo,
                                 AudioObjectID *outDeviceObjectID) {
  (void)description;
  (void)clientInfo;
  (void)outDeviceObjectID;
  return OSVAIsValidDriver(driver) ? kAudioHardwareUnsupportedOperationError
                                   : kAudioHardwareBadObjectError;
}

static OSStatus OSVADestroyDevice(AudioServerPlugInDriverRef driver,
                                  AudioObjectID deviceObjectID) {
  (void)deviceObjectID;
  return OSVAIsValidDriver(driver) ? kAudioHardwareUnsupportedOperationError
                                   : kAudioHardwareBadObjectError;
}

static OSStatus
OSVAPerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                     AudioObjectID deviceObjectID,
                                     UInt64 changeAction, void *changeInfo) {
  (void)changeAction;
  (void)changeInfo;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
OSVAAbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                   AudioObjectID deviceObjectID,
                                   UInt64 changeAction, void *changeInfo) {
  (void)changeAction;
  (void)changeInfo;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OSVAWillDoIOOperation(AudioServerPlugInDriverRef driver,
                                      AudioObjectID deviceObjectID,
                                      UInt32 clientID, UInt32 operationID,
                                      Boolean *outWillDo,
                                      Boolean *outWillDoInPlace) {
  (void)clientID;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (outWillDo == NULL || outWillDoInPlace == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  bool supported = (OSVAIsVisibleDevice(deviceObjectID) &&
                    operationID == kAudioServerPlugInIOOperationReadInput) ||
                   (OSVAIsHiddenDevice(deviceObjectID) &&
                    operationID == kAudioServerPlugInIOOperationWriteMix);
  *outWillDo = supported;
  *outWillDoInPlace = supported;
  return noErr;
}

static OSStatus
OSVABeginIOOperation(AudioServerPlugInDriverRef driver,
                     AudioObjectID deviceObjectID, UInt32 clientID,
                     UInt32 operationID, UInt32 ioBufferFrameSize,
                     const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
  (void)ioBufferFrameSize;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (ioCycleInfo == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (operationID == kAudioServerPlugInIOOperationThread) {
    const OSVAEndpoint endpoint = OSVAIsVisibleDevice(deviceObjectID)
                                      ? OSVA_ENDPOINT_VISIBLE_INPUT
                                      : OSVA_ENDPOINT_HIDDEN_WRITER;
    OSVAPublishIOWorkLoopDiagnostic(endpoint, clientID, true);
  }
  return noErr;
}

static OSStatus OSVAStatusToOSStatus(OSVAStatus status) {
  switch (status) {
  case OSVA_STATUS_OK:
    return noErr;
  case OSVA_STATUS_INVALID_ARGUMENT:
  case OSVA_STATUS_LIFECYCLE_ERROR:
  case OSVA_STATUS_CLIENT_ALREADY_STARTED:
  case OSVA_STATUS_NO_ACTIVE_TIMELINE:
  case OSVA_STATUS_INACTIVE_CLIENT:
  case OSVA_STATUS_STALE_CLIENT_LEASE:
  case OSVA_STATUS_ENDPOINT_MISMATCH:
    return kAudioHardwareIllegalOperationError;
  default:
    return kAudioHardwareUnspecifiedError;
  }
}

static OSStatus OSVARealTimeIOStatus(OSVAStatus status) {
  switch (status) {
  case OSVA_STATUS_OK:
  case OSVA_STATUS_RETRY:
  case OSVA_STATUS_INACTIVE_CLIENT:
  case OSVA_STATUS_STALE_CLIENT_LEASE:
    /*
     * A lifecycle transition on the sibling endpoint must not fault this
     * device's I/O engine. Input has already been zero-filled; output is
     * safely dropped for this cycle.
     */
    return noErr;
  default:
    return OSVAStatusToOSStatus(status);
  }
}

static uint64_t OSVAHostClockNow(void *context) {
  (void)context;
  return mach_absolute_time();
}

static OSVAEndpoint OSVAEndpointForDevice(AudioObjectID deviceObjectID) {
  return OSVAIsVisibleDevice(deviceObjectID) ? OSVA_ENDPOINT_VISIBLE_INPUT
                                             : OSVA_ENDPOINT_HIDDEN_WRITER;
}

static uint64_t OSVACoreClientID(AudioObjectID deviceObjectID,
                                 UInt32 clientID) {
  return ((uint64_t)deviceObjectID << 32U) | (uint64_t)clientID;
}

static OSVADriverClient *OSVAFindDriverClient(AudioObjectID deviceObjectID,
                                              UInt32 clientID) {
  for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    if (gDriverClients[index].registered &&
        gDriverClients[index].device_object_id == deviceObjectID &&
        gDriverClients[index].client_id == clientID) {
      return &gDriverClients[index];
    }
  }
  return NULL;
}

static OSVADriverClient *OSVAFindFreeDriverClient(void) {
  for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    if (!gDriverClients[index].registered) {
      return &gDriverClients[index];
    }
  }
  return NULL;
}

static size_t OSVAStartedClientCount(AudioObjectID deviceObjectID) {
  size_t count = 0;
  for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    if (gDriverClients[index].registered && gDriverClients[index].started &&
        gDriverClients[index].device_object_id == deviceObjectID) {
      count += 1;
    }
  }
  return count;
}

static void OSVANotifyRunningChanged(AudioServerPlugInHostRef host,
                                     AudioObjectID deviceObjectID) {
  if (host == NULL || host->PropertiesChanged == NULL) {
    return;
  }
  AudioObjectPropertyAddress address = {
      .mSelector = kAudioDevicePropertyDeviceIsRunning,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  (void)host->PropertiesChanged(host, deviceObjectID, 1, &address);
}

static OSStatus OSVAInitialize(AudioServerPlugInDriverRef driver,
                               AudioServerPlugInHostRef host) {
  if (!OSVAIsValidDriver(driver)) {
    return kAudioHardwareBadObjectError;
  }
  if (host == NULL) {
    return kAudioHardwareIllegalOperationError;
  }

  pthread_mutex_lock(&gStateMutex);
  if (gCoreInitialized) {
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
  }

  mach_timebase_info_data_t timebase = {0};
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }
  const __uint128_t ticksNumerator =
      (__uint128_t)UINT64_C(1000000000) * (uint64_t)timebase.denom;
  if (ticksNumerator == 0 || ticksNumerator > UINT64_MAX ||
      ticksNumerator % (uint64_t)timebase.numer != 0) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }
  const uint64_t hostTicksPerSecond =
      (uint64_t)(ticksNumerator / (uint64_t)timebase.numer);
  if (!atomic_is_lock_free(&gZeroTimestampCache.sequence) ||
      !atomic_is_lock_free(&gZeroTimestampCache.sample_frame) ||
      !atomic_is_lock_free(&gZeroTimestampCache.host_ticks) ||
      !atomic_is_lock_free(&gZeroTimestampCache.seed) ||
      !atomic_is_lock_free(&gZeroTimestampCache.lifecycle_sequence) ||
      !OSVADiagnosticAtomicsAreLockFree()) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }

  memset(&gCore, 0, sizeof(gCore));
  memset(gCoreClients, 0, sizeof(gCoreClients));
  memset(gRingStorage, 0, sizeof(gRingStorage));
  memset(gDriverClients, 0, sizeof(gDriverClients));
  memset(&gDiagnosticLifecycle, 0, sizeof(gDiagnosticLifecycle));
  uint64_t driverInstanceGeneration = mach_absolute_time();
  if (driverInstanceGeneration == 0 ||
      driverInstanceGeneration <= gLastDriverInstanceGeneration) {
    if (gLastDriverInstanceGeneration == UINT64_MAX) {
      pthread_mutex_unlock(&gStateMutex);
      return kAudioHardwareUnspecifiedError;
    }
    driverInstanceGeneration = gLastDriverInstanceGeneration + 1;
  }
  gLastDriverInstanceGeneration = driverInstanceGeneration;
  gDiagnosticLifecycle.driver_instance_generation =
      driverInstanceGeneration;
  gDiagnosticLifecycle.lifecycle_sequence = 1;
  OSVAResetDiagnosticAtomics();
  OSVAStatus status = OSVACoreInitialize(
      &gCore, gRingStorage, OSVA_PRODUCTION_RING_CAPACITY_FRAMES, gCoreClients,
      OSVA_DRIVER_CLIENT_SLOT_COUNT, OSVAHostClockNow, NULL, hostTicksPerSecond,
      0);
  if (status == OSVA_STATUS_OK) {
    gHost = host;
    gCoreInitialized = true;
  }
  pthread_mutex_unlock(&gStateMutex);
  return OSVAStatusToOSStatus(status);
}

static bool OSVACopyActiveLease(AudioObjectID deviceObjectID, UInt32 clientID,
                                OSVAClientLease *leaseOut) {
  if (!atomic_load_explicit(&gCoreInitialized, memory_order_acquire)) {
    return false;
  }
  uint64_t expectedClientID = OSVACoreClientID(deviceObjectID, clientID);
  OSVAEndpoint expectedEndpoint = OSVAEndpointForDevice(deviceObjectID);
  for (uint32_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
    uint64_t sessionID = atomic_load_explicit(&gCoreClients[index].session_id,
                                              memory_order_acquire);
    if (sessionID == 0) {
      continue;
    }
    OSVAClientLease candidate = {
        .client_id = atomic_load_explicit(&gCoreClients[index].client_id,
                                          memory_order_relaxed),
        .session_id = sessionID,
        .timeline_seed = atomic_load_explicit(
            &gCoreClients[index].timeline_seed, memory_order_relaxed),
        .client_slot = index,
        .endpoint = (OSVAEndpoint)atomic_load_explicit(
            &gCoreClients[index].endpoint, memory_order_relaxed),
    };
    if (candidate.client_id == expectedClientID &&
        candidate.endpoint == expectedEndpoint &&
        OSVACoreClientLeaseIsActive(&gCore, candidate)) {
      *leaseOut = candidate;
      return true;
    }
  }
  return false;
}

static bool OSVAStoreZeroTimestampCache(OSVAZeroTimestamp timestamp) {
  if (timestamp.seed == 0) {
    return false;
  }
  for (unsigned attempt = 0; attempt < OSVA_TIMESTAMP_CACHE_ATTEMPT_LIMIT;
       ++attempt) {
    uint64_t sequence = atomic_load_explicit(&gZeroTimestampCache.sequence,
                                             memory_order_acquire);
    if ((sequence & UINT64_C(1)) != 0 || sequence > UINT64_MAX - 2) {
      continue;
    }
    uint64_t oddSequence = sequence + 1;
    if (!atomic_compare_exchange_weak_explicit(
            &gZeroTimestampCache.sequence, &sequence, oddSequence,
            memory_order_acq_rel, memory_order_acquire)) {
      continue;
    }

    uint64_t cachedSeed =
        atomic_load_explicit(&gZeroTimestampCache.seed, memory_order_relaxed);
    uint64_t cachedSample = atomic_load_explicit(
        &gZeroTimestampCache.sample_frame, memory_order_relaxed);
    bool replacesOlderTimeline = cachedSeed == 0 || timestamp.seed > cachedSeed;
    bool advancesCurrentTimeline =
        cachedSeed == timestamp.seed && cachedSample <= timestamp.sample_frame;
    if (replacesOlderTimeline || advancesCurrentTimeline) {
      atomic_store_explicit(&gZeroTimestampCache.sample_frame,
                            timestamp.sample_frame, memory_order_relaxed);
      atomic_store_explicit(&gZeroTimestampCache.host_ticks,
                            timestamp.host_ticks, memory_order_relaxed);
      atomic_store_explicit(&gZeroTimestampCache.seed, timestamp.seed,
                            memory_order_relaxed);
      atomic_store_explicit(&gZeroTimestampCache.lifecycle_sequence,
                            timestamp.lifecycle_sequence,
                            memory_order_relaxed);
    }
    atomic_store_explicit(&gZeroTimestampCache.sequence, oddSequence + 1,
                          memory_order_release);
    return true;
  }
  return false;
}

static bool OSVALoadZeroTimestampCache(OSVAZeroTimestamp *timestampOut) {
  for (unsigned attempt = 0; attempt < OSVA_TIMESTAMP_CACHE_ATTEMPT_LIMIT;
       ++attempt) {
    uint64_t before = atomic_load_explicit(&gZeroTimestampCache.sequence,
                                           memory_order_acquire);
    if ((before & UINT64_C(1)) != 0) {
      continue;
    }
    OSVAZeroTimestamp timestamp = {
        .sample_frame = atomic_load_explicit(&gZeroTimestampCache.sample_frame,
                                             memory_order_relaxed),
        .host_ticks = atomic_load_explicit(&gZeroTimestampCache.host_ticks,
                                           memory_order_relaxed),
        .seed = atomic_load_explicit(&gZeroTimestampCache.seed,
                                     memory_order_relaxed),
        .lifecycle_sequence = atomic_load_explicit(
            &gZeroTimestampCache.lifecycle_sequence, memory_order_relaxed),
    };
    atomic_thread_fence(memory_order_acquire);
    uint64_t after = atomic_load_explicit(&gZeroTimestampCache.sequence,
                                          memory_order_acquire);
    if (before == after && (after & UINT64_C(1)) == 0 && timestamp.seed != 0) {
      *timestampOut = timestamp;
      return true;
    }
  }
  return false;
}

#if defined(OSVA_DRIVER_TESTING)
static bool OSVAConsumeZeroTimeStampFenceForTesting(void) {
  uint32_t remaining = atomic_load_explicit(
      &gFenceZeroTimeStampCallCountForTesting, memory_order_acquire);
  while (remaining > 0) {
    if (atomic_compare_exchange_weak_explicit(
            &gFenceZeroTimeStampCallCountForTesting, &remaining, remaining - 1,
            memory_order_acq_rel, memory_order_acquire)) {
      return true;
    }
  }
  return false;
}

static void OSVAMaybePauseZeroTimestampPublicationForTesting(void) {
  if (!atomic_exchange_explicit(
          &gPauseNextZeroTimestampPublicationForTesting, false,
          memory_order_acq_rel)) {
    return;
  }
  atomic_store_explicit(&gZeroTimestampPublicationPausedForTesting, true,
                        memory_order_release);
  while (!atomic_load_explicit(&gResumeZeroTimestampPublicationForTesting,
                               memory_order_acquire)) {
    sched_yield();
  }
  atomic_store_explicit(&gResumeZeroTimestampPublicationForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampPublicationPausedForTesting, false,
                        memory_order_release);
}
#endif

static OSVAStatus OSVAGetCoreZeroTimestamp(OSVAZeroTimestamp *timestampOut) {
#if defined(OSVA_DRIVER_TESTING)
  if (OSVAConsumeZeroTimeStampFenceForTesting()) {
    uint64_t oddSequence = 0;
    if (!OSVABeginLifecycleFenceForTesting(&oddSequence)) {
      return OSVA_STATUS_RETRY;
    }
    OSVAStatus status = OSVACoreGetZeroTimestamp(&gCore, timestampOut);
    OSVAEndLifecycleFenceForTesting(oddSequence);
    return status;
  }
#endif
  return OSVACoreGetZeroTimestamp(&gCore, timestampOut);
}

static OSStatus OSVAGetZeroTimeStamp(AudioServerPlugInDriverRef driver,
                                     AudioObjectID deviceObjectID,
                                     UInt32 clientID, Float64 *outSampleTime,
                                     UInt64 *outHostTime, UInt64 *outSeed) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!gCoreInitialized) {
    return kAudioHardwareIllegalOperationError;
  }
  const OSVAEndpoint endpoint = OSVAEndpointForDevice(deviceObjectID);
  const uint64_t callHostTicks = mach_absolute_time();
  OSVAStatus status = OSVA_STATUS_RETRY;
  OSVAZeroTimestamp timestamp = {0};
  for (unsigned attempt = 0; attempt < OSVA_ZERO_TIMESTAMP_RETRY_LIMIT;
       ++attempt) {
    status = OSVAGetCoreZeroTimestamp(&timestamp);
    if (status == OSVA_STATUS_OK) {
      const uint64_t seedGeneration = timestamp.seed;
      const bool epochMappingAvailable = seedGeneration != 0;
      (void)OSVAStoreZeroTimestampCache(timestamp);
      *outSampleTime = (Float64)timestamp.sample_frame;
      *outHostTime = timestamp.host_ticks;
      *outSeed = timestamp.seed;
#if defined(OSVA_DRIVER_TESTING)
      OSVAMaybePauseZeroTimestampPublicationForTesting();
#endif
      OSVAPublishZeroTimestampDiagnostic(
          endpoint, clientID, callHostTicks, timestamp.lifecycle_sequence,
          status, &timestamp, seedGeneration, epochMappingAvailable, false);
      return noErr;
    }
    if (status != OSVA_STATUS_RETRY) {
      OSVAPublishZeroTimestampDiagnostic(
          endpoint, clientID, callHostTicks,
          atomic_load_explicit(&gCore.lifecycle_sequence,
                               memory_order_acquire),
          status, NULL, 0, false, false);
      return OSVAStatusToOSStatus(status);
    }
  }

  uint64_t activeSeedBefore =
      atomic_load_explicit(&gCore.timeline_seed, memory_order_acquire);
  bool loadedCachedTimestamp = OSVALoadZeroTimestampCache(&timestamp);
  uint64_t activeSeedAfter =
      atomic_load_explicit(&gCore.timeline_seed, memory_order_acquire);
  if (activeSeedBefore != 0 && activeSeedBefore == activeSeedAfter &&
      loadedCachedTimestamp && timestamp.seed == activeSeedBefore) {
    const uint64_t seedGeneration = timestamp.seed;
    const bool epochMappingAvailable = seedGeneration != 0;
    *outSampleTime = (Float64)timestamp.sample_frame;
    *outHostTime = timestamp.host_ticks;
    *outSeed = timestamp.seed;
#if defined(OSVA_DRIVER_TESTING)
    OSVAMaybePauseZeroTimestampPublicationForTesting();
#endif
    OSVAPublishZeroTimestampDiagnostic(
        endpoint, clientID, callHostTicks, timestamp.lifecycle_sequence,
        OSVA_STATUS_OK, &timestamp, seedGeneration, epochMappingAvailable,
        true);
    return noErr;
  }
  OSVAPublishZeroTimestampDiagnostic(
      endpoint, clientID, callHostTicks,
      atomic_load_explicit(&gCore.lifecycle_sequence, memory_order_acquire),
      status, NULL, 0, false, false);
  return OSVAStatusToOSStatus(status);
}

static bool OSVAGetIntegralCycleFrame(const AudioTimeStamp *timestamp,
                                      uint64_t *frameOut) {
  if ((timestamp->mFlags & kAudioTimeStampSampleTimeValid) == 0) {
    return false;
  }
  Float64 sampleTime = timestamp->mSampleTime;
  if (!isfinite(sampleTime) || sampleTime < 0.0 ||
      sampleTime >= 18446744073709551616.0 || floor(sampleTime) != sampleTime) {
    return false;
  }
  *frameOut = (uint64_t)sampleTime;
  return true;
}

#if defined(OSVA_DRIVER_TESTING)
static bool OSVABeginLifecycleFenceForTesting(uint64_t *oddSequenceOut) {
  uint64_t sequence =
      atomic_load_explicit(&gCore.lifecycle_sequence, memory_order_acquire);
  if ((sequence & UINT64_C(1)) != 0 || sequence > UINT64_MAX - 2) {
    return false;
  }
  *oddSequenceOut = sequence + 1;
  atomic_store_explicit(&gCore.lifecycle_sequence, *oddSequenceOut,
                        memory_order_release);
  return true;
}

static void OSVAEndLifecycleFenceForTesting(uint64_t oddSequence) {
  atomic_store_explicit(&gCore.lifecycle_sequence, oddSequence + 1,
                        memory_order_release);
}
#endif

static OSStatus
OSVADoIOOperation(AudioServerPlugInDriverRef driver,
                  AudioObjectID deviceObjectID, AudioObjectID streamObjectID,
                  UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize,
                  const AudioServerPlugInIOCycleInfo *ioCycleInfo,
                  void *ioMainBuffer, void *ioSecondaryBuffer) {
  (void)ioSecondaryBuffer;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }

  AudioObjectID expectedStream = OSVAIsVisibleDevice(deviceObjectID)
                                     ? kOSVAObjectIDVisibleInputStream
                                     : kOSVAObjectIDHiddenWriterStream;
  if (streamObjectID != expectedStream) {
    return kAudioHardwareBadStreamError;
  }
  UInt32 expectedOperation = OSVAIsVisibleDevice(deviceObjectID)
                                 ? kAudioServerPlugInIOOperationReadInput
                                 : kAudioServerPlugInIOOperationWriteMix;
  if (operationID != expectedOperation) {
    return kAudioHardwareUnsupportedOperationError;
  }
  if (ioCycleInfo == NULL || ioMainBuffer == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if ((size_t)ioBufferFrameSize > SIZE_MAX / sizeof(Float32)) {
    return kAudioHardwareIllegalOperationError;
  }
  size_t frameCount = (size_t)ioBufferFrameSize;
  size_t byteCount = frameCount * sizeof(Float32);
  const bool isVisible = OSVAIsVisibleDevice(deviceObjectID);
  const OSVAEndpoint endpoint = OSVAEndpointForDevice(deviceObjectID);
  OSVAIODiagnosticObservation diagnostic = {
      .writer = !isVisible,
      .requested_frames = (uint64_t)frameCount,
      .gap_frames = (uint64_t)frameCount,
      .cycle_host_ticks = mach_absolute_time(),
      .client_id = clientID,
      .status = OSVA_STATUS_INVALID_ARGUMENT,
  };
  if (isVisible) {
    memset(ioMainBuffer, 0, byteCount);
  }

  uint64_t startFrame = 0;
  const AudioTimeStamp *cycleTimestamp = OSVAIsVisibleDevice(deviceObjectID)
                                             ? &ioCycleInfo->mInputTime
                                             : &ioCycleInfo->mOutputTime;
  if (!OSVAGetIntegralCycleFrame(cycleTimestamp, &startFrame)) {
    atomic_fetch_add_explicit(&gInvalidCycleTimestampCount, 1,
                              memory_order_relaxed);
    OSVAPublishIODiagnostic(endpoint, diagnostic);
    return noErr;
  }
  diagnostic.valid_cycle = true;
  diagnostic.cycle_sample_frame = startFrame;

  OSVAClientLease lease;
  if (!OSVACopyActiveLease(deviceObjectID, clientID, &lease)) {
    /* A sibling StartIO/StopIO may temporarily fence every lease snapshot. */
    diagnostic.status = OSVA_STATUS_INACTIVE_CLIENT;
    OSVAPublishIODiagnostic(endpoint, diagnostic);
    return noErr;
  }
  diagnostic.lease_available = true;
  diagnostic.seed_generation = lease.timeline_seed;
  diagnostic.epoch_mapping_available = diagnostic.seed_generation != 0;

#if defined(OSVA_DRIVER_TESTING)
  uint64_t testingFenceSequence = 0;
  bool testingFenceActive = atomic_exchange_explicit(
      &gFenceNextIOForTesting, false, memory_order_acq_rel);
  if (testingFenceActive &&
      !OSVABeginLifecycleFenceForTesting(&testingFenceSequence)) {
    diagnostic.status = OSVA_STATUS_LIFECYCLE_ERROR;
    OSVAPublishIODiagnostic(endpoint, diagnostic);
    return kAudioHardwareIllegalOperationError;
  }
#endif

  OSVAStatus status;
  diagnostic.core_called = true;
  if (isVisible) {
    OSVAReadResult result = {
        .requested_frames = frameCount,
        .underrun_frames = frameCount,
    };
    status = OSVACoreReadFrames(&gCore, lease, startFrame,
                                (Float32 *)ioMainBuffer, frameCount, &result);
    diagnostic.transferred_frames = (uint64_t)result.delivered_frames;
    diagnostic.gap_frames = (uint64_t)result.underrun_frames;
    diagnostic.has_transferred_frame = result.has_last_transferred_frame;
    diagnostic.transferred_seed = result.last_transferred_timeline_seed;
    diagnostic.transferred_session = result.last_transferred_session_id;
    diagnostic.transferred_absolute_frame =
        result.last_transferred_absolute_frame;
  } else {
    OSVAWriteResult result = {
        .requested_frames = frameCount,
    };
    status =
        OSVACoreWriteFrames(&gCore, lease, startFrame,
                            (const Float32 *)ioMainBuffer, frameCount, &result);
    diagnostic.transferred_frames = (uint64_t)result.written_frames;
    diagnostic.gap_frames = (uint64_t)result.contended_frames;
    diagnostic.has_transferred_frame = result.has_last_transferred_frame;
    diagnostic.transferred_seed = result.last_transferred_timeline_seed;
    diagnostic.transferred_session = result.last_transferred_session_id;
    diagnostic.transferred_absolute_frame =
        result.last_transferred_absolute_frame;
  }
  diagnostic.status = status;

#if defined(OSVA_DRIVER_TESTING)
  if (testingFenceActive) {
    OSVAEndLifecycleFenceForTesting(testingFenceSequence);
  }
#endif
  OSVAPublishIODiagnostic(endpoint, diagnostic);
  return OSVARealTimeIOStatus(status);
}

#if defined(OSVA_DRIVER_TESTING)
OSStatus OSVADriverFenceNextIOForTesting(void) {
  pthread_mutex_lock(&gStateMutex);
  bool initialized =
      atomic_load_explicit(&gCoreInitialized, memory_order_acquire);
  bool alreadyPending =
      atomic_load_explicit(&gFenceNextIOForTesting, memory_order_acquire);
  uint64_t sequence =
      atomic_load_explicit(&gCore.lifecycle_sequence, memory_order_acquire);
  if (!initialized || alreadyPending || (sequence & UINT64_C(1)) != 0 ||
      sequence > UINT64_MAX - 2) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gFenceNextIOForTesting, true, memory_order_release);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

OSStatus OSVADriverFenceZeroTimeStampCallsForTesting(UInt32 callCount) {
  pthread_mutex_lock(&gStateMutex);
  if (!atomic_load_explicit(&gCoreInitialized, memory_order_acquire)) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gFenceZeroTimeStampCallCountForTesting, callCount,
                        memory_order_release);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

OSStatus OSVADriverPauseNextZeroTimestampPublicationForTesting(void) {
  pthread_mutex_lock(&gStateMutex);
  const bool initialized =
      atomic_load_explicit(&gCoreInitialized, memory_order_acquire);
  const bool pending = atomic_load_explicit(
      &gPauseNextZeroTimestampPublicationForTesting, memory_order_acquire);
  const bool paused = atomic_load_explicit(
      &gZeroTimestampPublicationPausedForTesting, memory_order_acquire);
  if (!initialized || pending || paused) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gResumeZeroTimestampPublicationForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gPauseNextZeroTimestampPublicationForTesting, true,
                        memory_order_release);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

Boolean OSVADriverZeroTimestampPublicationIsPausedForTesting(void) {
  return atomic_load_explicit(&gZeroTimestampPublicationPausedForTesting,
                              memory_order_acquire);
}

OSStatus OSVADriverResumeZeroTimestampPublicationForTesting(void) {
  if (!atomic_load_explicit(&gZeroTimestampPublicationPausedForTesting,
                            memory_order_acquire)) {
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gResumeZeroTimestampPublicationForTesting, true,
                        memory_order_release);
  return noErr;
}

OSStatus OSVADriverForceNextIOWorkLoopCurrentCountDropForTesting(void) {
  pthread_mutex_lock(&gStateMutex);
  const bool initialized =
      atomic_load_explicit(&gCoreInitialized, memory_order_acquire);
  const bool pending = atomic_load_explicit(
      &gForceNextIOWorkLoopCurrentCountDropForTesting, memory_order_acquire);
  if (!initialized || pending) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gForceNextIOWorkLoopCurrentCountDropForTesting, true,
                        memory_order_release);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

OSStatus OSVADriverHoldNextDiagnosticRecordWriterForTesting(
    UInt32 recordKind, UInt32 endpointRole) {
  const bool validKind =
      recordKind == kOSVADriverTestDiagnosticRecordZeroTimestamp ||
      recordKind == kOSVADriverTestDiagnosticRecordIO ||
      recordKind == kOSVADriverTestDiagnosticRecordIOWorkLoopMetadata;
  const bool validEndpoint =
      endpointRole == kOSVADiagnosticEndpointVisibleInput ||
      endpointRole == kOSVADiagnosticEndpointHiddenWriter;
  if (!validKind || !validEndpoint) {
    return kAudioHardwareIllegalOperationError;
  }

  pthread_mutex_lock(&gStateMutex);
  const bool initialized =
      atomic_load_explicit(&gCoreInitialized, memory_order_acquire);
  const bool pending = atomic_load_explicit(
      &gHeldDiagnosticRecordKindForTesting, memory_order_acquire) != 0;
  const bool held = atomic_load_explicit(
      &gDiagnosticRecordWriterHeldForTesting, memory_order_acquire);
  if (!initialized || pending || held) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  const size_t endpointIndex =
      endpointRole == kOSVADiagnosticEndpointHiddenWriter ? 1U : 0U;
  atomic_store_explicit(&gHeldDiagnosticEndpointIndexForTesting,
                        (uint32_t)endpointIndex, memory_order_relaxed);
  atomic_store_explicit(&gResumeDiagnosticRecordWriterForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gHeldDiagnosticRecordKindForTesting, recordKind,
                        memory_order_release);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

Boolean OSVADriverDiagnosticRecordWriterIsHeldForTesting(void) {
  return atomic_load_explicit(&gDiagnosticRecordWriterHeldForTesting,
                              memory_order_acquire);
}

OSStatus OSVADriverResumeDiagnosticRecordWriterForTesting(void) {
  if (!atomic_load_explicit(&gDiagnosticRecordWriterHeldForTesting,
                            memory_order_acquire)) {
    return kAudioHardwareIllegalOperationError;
  }
  atomic_store_explicit(&gResumeDiagnosticRecordWriterForTesting, true,
                        memory_order_release);
  return noErr;
}

OSStatus OSVADriverResetForTesting(void) {
  pthread_mutex_lock(&gStateMutex);
  OSVAStatus status = OSVA_STATUS_OK;
  if (gCoreInitialized) {
    for (size_t index = 0; index < OSVA_DRIVER_CLIENT_SLOT_COUNT; ++index) {
      if (gDriverClients[index].registered && gDriverClients[index].started) {
        OSVAStatus stopStatus =
            OSVACoreStopClient(&gCore, gDriverClients[index].lease);
        if (status == OSVA_STATUS_OK && stopStatus != OSVA_STATUS_OK) {
          status = stopStatus;
        }
      }
    }
    if (status == OSVA_STATUS_OK) {
      status = OSVACoreDestroy(&gCore);
    }
  }
  if (status != OSVA_STATUS_OK) {
    pthread_mutex_unlock(&gStateMutex);
    return OSVAStatusToOSStatus(status);
  }
  memset(&gCore, 0, sizeof(gCore));
  memset(gCoreClients, 0, sizeof(gCoreClients));
  memset(gRingStorage, 0, sizeof(gRingStorage));
  memset(gDriverClients, 0, sizeof(gDriverClients));
  memset(&gDiagnosticLifecycle, 0, sizeof(gDiagnosticLifecycle));
  OSVAResetDiagnosticAtomics();
  gCoreInitialized = false;
  gHost = NULL;
  atomic_store_explicit(&gReferenceCount, 1, memory_order_relaxed);
  atomic_store_explicit(&gInvalidCycleTimestampCount, 0, memory_order_relaxed);
  atomic_store_explicit(&gFenceNextIOForTesting, false, memory_order_relaxed);
  atomic_store_explicit(&gFenceZeroTimeStampCallCountForTesting, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gPauseNextZeroTimestampPublicationForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampPublicationPausedForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gResumeZeroTimestampPublicationForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gForceNextIOWorkLoopCurrentCountDropForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gHeldDiagnosticRecordKindForTesting, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gHeldDiagnosticEndpointIndexForTesting, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gDiagnosticRecordWriterHeldForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gResumeDiagnosticRecordWriterForTesting, false,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.sequence, 0, memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.sample_frame, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.host_ticks, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.seed, 0, memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.lifecycle_sequence, 0,
                        memory_order_relaxed);
  pthread_mutex_unlock(&gStateMutex);
  return OSVAStatusToOSStatus(status);
}
#endif

static OSStatus
OSVAAddDeviceClient(AudioServerPlugInDriverRef driver,
                    AudioObjectID deviceObjectID,
                    const AudioServerPlugInClientInfo *clientInfo) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (clientInfo == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  pthread_mutex_lock(&gStateMutex);
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.driver_client_add_attempt_count);
  OSVAAdvanceDiagnosticLifecycleSequence();
  if (!gCoreInitialized ||
      OSVAFindDriverClient(deviceObjectID, clientInfo->mClientID) != NULL) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  OSVADriverClient *client = OSVAFindFreeDriverClient();
  if (client == NULL) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }
  if (client->generation == UINT64_MAX) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }
  const size_t slotIndex = (size_t)(client - gDriverClients);
  const uint64_t generation = client->generation + 1;
  const uint64_t transitionHostTicks = mach_absolute_time();
  const uint64_t activeCount = atomic_load_explicit(
      &gCore.active_client_count, memory_order_relaxed);
  memset(client, 0, sizeof(*client));
  client->generation = generation;
  client->registered = true;
  client->device_object_id = deviceObjectID;
  client->client_id = clientInfo->mClientID;
  client->process_id = clientInfo->mProcessID;
  client->registration_host_ticks = transitionHostTicks;
  client->last_transition_host_ticks = transitionHostTicks;
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.driver_client_add_count);
  OSVARecordDiagnosticTransition(
      &gDiagnosticLifecycle.last_driver_transition,
      kOSVADiagnosticTransitionDriverClientAdded,
      OSVAEndpointForDevice(deviceObjectID), slotIndex,
      (uint64_t)clientInfo->mClientID, clientInfo->mProcessID, generation, 0,
      activeCount, activeCount, transitionHostTicks);
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

static OSStatus
OSVARemoveDeviceClient(AudioServerPlugInDriverRef driver,
                       AudioObjectID deviceObjectID,
                       const AudioServerPlugInClientInfo *clientInfo) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (clientInfo == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  pthread_mutex_lock(&gStateMutex);
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.driver_client_remove_attempt_count);
  OSVAAdvanceDiagnosticLifecycleSequence();
  OSVADriverClient *client =
      OSVAFindDriverClient(deviceObjectID, clientInfo->mClientID);
  if (client == NULL || client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  const size_t slotIndex = (size_t)(client - gDriverClients);
  const uint64_t generation = client->generation;
  const uint64_t transitionHostTicks = mach_absolute_time();
  const uint64_t activeCount = atomic_load_explicit(
      &gCore.active_client_count, memory_order_relaxed);
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.driver_client_remove_count);
  OSVARecordDiagnosticTransition(
      &gDiagnosticLifecycle.last_driver_transition,
      kOSVADiagnosticTransitionDriverClientRemoved,
      OSVAEndpointForDevice(deviceObjectID), slotIndex,
      (uint64_t)clientInfo->mClientID, client->process_id, generation, 0,
      activeCount, activeCount, transitionHostTicks);
  memset(client, 0, sizeof(*client));
  client->generation = generation;
  client->last_transition_host_ticks = transitionHostTicks;
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

static OSStatus OSVAStartIO(AudioServerPlugInDriverRef driver,
                            AudioObjectID deviceObjectID, UInt32 clientID) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gStateMutex);
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.global_start_attempt_count);
  OSVAAdvanceDiagnosticLifecycleSequence();
  OSVADriverClient *client = OSVAFindDriverClient(deviceObjectID, clientID);
  if (!gCoreInitialized || client == NULL || client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  const OSVAEndpoint endpoint = OSVAEndpointForDevice(deviceObjectID);
  const size_t driverSlotIndex = (size_t)(client - gDriverClients);
  const uint64_t coreClientID = OSVACoreClientID(deviceObjectID, clientID);
  const uint64_t transitionHostTicks = mach_absolute_time();
  const uint64_t preActiveCount = atomic_load_explicit(
      &gCore.active_client_count, memory_order_relaxed);
  bool notify = OSVAStartedClientCount(deviceObjectID) == 0;
  OSVAStatus status = OSVACoreStartClient(
      &gCore, endpoint, coreClientID, &client->lease);
  if (status == OSVA_STATUS_OK) {
    const uint64_t postActiveCount = atomic_load_explicit(
        &gCore.active_client_count, memory_order_relaxed);
    client->started = true;
    client->io_start_depth = 1;
    client->start_host_ticks = transitionHostTicks;
    client->last_transition_host_ticks = transitionHostTicks;
    OSVAIncrementDiagnosticCounter(
        &gDiagnosticLifecycle.global_start_transition_count);
    const bool createdSeed = preActiveCount == 0 && postActiveCount == 1;
    if (createdSeed) {
      OSVAIncrementDiagnosticCounter(&gDiagnosticLifecycle.seed_create_count);
      gDiagnosticLifecycle.current_seed_generation =
          client->lease.timeline_seed;
      gDiagnosticLifecycle.last_seed_create_host_ticks = transitionHostTicks;
    }
    OSVARecordDiagnosticTransition(
        &gDiagnosticLifecycle.last_driver_transition,
        kOSVADiagnosticTransitionIOStarted, endpoint, driverSlotIndex,
        (uint64_t)clientID, client->process_id, client->generation,
        client->lease.session_id, preActiveCount, postActiveCount,
        transitionHostTicks);
    OSVARecordDiagnosticTransition(
        &gDiagnosticLifecycle.last_core_transition,
        createdSeed ? kOSVADiagnosticTransitionSeedCreated
                    : kOSVADiagnosticTransitionIOStarted,
        endpoint, client->lease.client_slot, coreClientID, client->process_id,
        client->generation, client->lease.session_id, preActiveCount,
        postActiveCount, transitionHostTicks);
    OSVAZeroTimestamp timestamp;
    if (OSVACoreGetZeroTimestamp(&gCore, &timestamp) == OSVA_STATUS_OK) {
      (void)OSVAStoreZeroTimestampCache(timestamp);
    }
  }
  AudioServerPlugInHostRef host = gHost;
  pthread_mutex_unlock(&gStateMutex);
  if (status == OSVA_STATUS_OK && notify) {
    OSVANotifyRunningChanged(host, deviceObjectID);
  }
  return OSVAStatusToOSStatus(status);
}

static OSStatus OSVAStopIO(AudioServerPlugInDriverRef driver,
                           AudioObjectID deviceObjectID, UInt32 clientID) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gStateMutex);
  OSVAIncrementDiagnosticCounter(
      &gDiagnosticLifecycle.global_stop_attempt_count);
  OSVAAdvanceDiagnosticLifecycleSequence();
  OSVADriverClient *client = OSVAFindDriverClient(deviceObjectID, clientID);
  if (!gCoreInitialized || client == NULL || !client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  const OSVAEndpoint endpoint = OSVAEndpointForDevice(deviceObjectID);
  const size_t driverSlotIndex = (size_t)(client - gDriverClients);
  const uint64_t coreClientID = OSVACoreClientID(deviceObjectID, clientID);
  const uint32_t coreSlotIndex = client->lease.client_slot;
  const uint64_t coreSessionID = client->lease.session_id;
  const uint64_t driverClientGeneration = client->generation;
  const pid_t processID = client->process_id;
  const uint64_t transitionHostTicks = mach_absolute_time();
  const uint64_t preActiveCount = atomic_load_explicit(
      &gCore.active_client_count, memory_order_relaxed);
  const uint64_t retiringSeed = atomic_load_explicit(
      &gCore.timeline_seed, memory_order_relaxed);
  const uint64_t retiringAnchor = atomic_load_explicit(
      &gCore.anchor_host_ticks, memory_order_relaxed);
  bool notify = OSVAStartedClientCount(deviceObjectID) == 1;
  OSVAStatus status = OSVACoreStopClient(&gCore, client->lease);
  if (status == OSVA_STATUS_OK) {
    const uint64_t postActiveCount = atomic_load_explicit(
        &gCore.active_client_count, memory_order_relaxed);
    OSVAIncrementDiagnosticCounter(
        &gDiagnosticLifecycle.global_stop_transition_count);
    const bool clearedSeed = preActiveCount == 1 && postActiveCount == 0;
    if (clearedSeed) {
      OSVAIncrementDiagnosticCounter(&gDiagnosticLifecycle.seed_clear_count);
      gDiagnosticLifecycle.last_seed_clear_host_ticks = transitionHostTicks;
      gDiagnosticLifecycle.last_cleared_seed = retiringSeed;
      gDiagnosticLifecycle.last_cleared_seed_generation =
          retiringSeed;
      gDiagnosticLifecycle.last_cleared_anchor_host_ticks = retiringAnchor;
      gDiagnosticLifecycle.current_seed_generation = 0;
    }
    OSVARecordDiagnosticTransition(
        &gDiagnosticLifecycle.last_driver_transition,
        kOSVADiagnosticTransitionIOStopped, endpoint, driverSlotIndex,
        (uint64_t)clientID, processID, driverClientGeneration, coreSessionID,
        preActiveCount, postActiveCount, transitionHostTicks);
    OSVARecordDiagnosticTransition(
        &gDiagnosticLifecycle.last_core_transition,
        clearedSeed ? kOSVADiagnosticTransitionSeedCleared
                    : kOSVADiagnosticTransitionIOStopped,
        endpoint, coreSlotIndex, coreClientID, processID,
        driverClientGeneration, coreSessionID, preActiveCount,
        postActiveCount, transitionHostTicks);
    memset(&client->lease, 0, sizeof(client->lease));
    client->started = false;
    client->io_start_depth = 0;
    client->last_transition_host_ticks = transitionHostTicks;
  }
  AudioServerPlugInHostRef host = gHost;
  pthread_mutex_unlock(&gStateMutex);
  if (status == OSVA_STATUS_OK && notify) {
    OSVANotifyRunningChanged(host, deviceObjectID);
  }
  return OSVAStatusToOSStatus(status);
}

static OSStatus
OSVAEndIOOperation(AudioServerPlugInDriverRef driver,
                   AudioObjectID deviceObjectID, UInt32 clientID,
                   UInt32 operationID, UInt32 ioBufferFrameSize,
                   const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
  (void)ioBufferFrameSize;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (ioCycleInfo == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (operationID == kAudioServerPlugInIOOperationThread) {
    const OSVAEndpoint endpoint = OSVAIsVisibleDevice(deviceObjectID)
                                      ? OSVA_ENDPOINT_VISIBLE_INPUT
                                      : OSVA_ENDPOINT_HIDDEN_WRITER;
    OSVAPublishIOWorkLoopDiagnostic(endpoint, clientID, false);
  }
  return noErr;
}
