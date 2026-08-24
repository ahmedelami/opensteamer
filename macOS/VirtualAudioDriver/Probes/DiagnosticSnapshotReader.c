#include "OpensteamerVirtualMicrophoneDriver.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
  kReaderSchemaVersion = 1,
  kMaximumCoherenceAttempts = 8,
  kExitUsage = 64,
  kExitSchemaMismatch = 65,
  kExitPropertyUnavailable = 69,
  kExitInternalError = 70,
  kExitRetry = 75,
};

typedef enum SnapshotReadResult {
  kSnapshotReadOK = 0,
  kSnapshotReadSchemaMismatch,
  kSnapshotReadUnavailable,
  kSnapshotReadRetry,
  kSnapshotReadFailed,
} SnapshotReadResult;

typedef struct EndpointObservation {
  UInt64 snapshot_sequence;
  UInt64 captured_host_ticks;
} EndpointObservation;

_Static_assert(sizeof(AudioDeviceID) == sizeof(UInt32),
               "reader JSON assumes a 32-bit AudioDeviceID");
_Static_assert(sizeof(OSVADiagnosticTransitionSnapshot) == 72,
               "diagnostic transition schema changed");
_Static_assert(sizeof(OSVADiagnosticZeroTimestampSnapshot) == 136,
               "zero-timestamp diagnostic schema changed");
_Static_assert(sizeof(OSVADiagnosticIOSnapshot) == 208,
               "I/O diagnostic schema changed");
_Static_assert(sizeof(OSVADiagnosticIOWorkLoopSnapshot) == 72,
               "I/O work-loop diagnostic schema changed");
_Static_assert(sizeof(OSVADiagnosticSnapshot) ==
                   kOSVADiagnosticSnapshotByteCount,
               "diagnostic snapshot byte-count constant changed");
_Static_assert(sizeof(OSVADiagnosticSnapshot) <= UINT32_MAX,
               "diagnostic snapshot must fit Core Audio's UInt32 data size");
_Static_assert(kOSVADiagnosticEndpointVisibleInput == 1 &&
                   kOSVADiagnosticEndpointHiddenWriter == 2,
               "endpoint array indexing contract changed");

static AudioObjectPropertyAddress
PropertyAddress(AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress address = {
      .mSelector = selector,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  return address;
}

static OSStatus TranslateExactDeviceUID(const char *uid,
                                        AudioDeviceID *deviceID) {
  if (uid == NULL || deviceID == NULL) {
    return kAudio_ParamError;
  }
  *deviceID = kAudioObjectUnknown;
  CFStringRef qualifier = CFStringCreateWithCString(
      kCFAllocatorDefault, uid, kCFStringEncodingUTF8);
  if (qualifier == NULL) {
    return kAudio_MemFullError;
  }
  AudioObjectPropertyAddress address =
      PropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice);
  UInt32 size = (UInt32)sizeof(*deviceID);
  const OSStatus status = AudioObjectGetPropertyData(
      kAudioObjectSystemObject, &address, (UInt32)sizeof(qualifier), &qualifier,
      &size, deviceID);
  CFRelease(qualifier);
  if (status != noErr) {
    return status;
  }
  return size == sizeof(*deviceID) ? noErr : kAudioHardwareBadPropertySizeError;
}

static bool DeviceUIDMatches(AudioDeviceID deviceID, const char *expectedUID) {
  if (deviceID == kAudioObjectUnknown || expectedUID == NULL) {
    return false;
  }
  AudioObjectPropertyAddress address =
      PropertyAddress(kAudioDevicePropertyDeviceUID);
  CFStringRef actualUID = NULL;
  UInt32 size = (UInt32)sizeof(actualUID);
  const OSStatus status = AudioObjectGetPropertyData(
      deviceID, &address, 0, NULL, &size, &actualUID);
  if (status != noErr || size != sizeof(actualUID) || actualUID == NULL ||
      CFGetTypeID(actualUID) != CFStringGetTypeID()) {
    if (actualUID != NULL) {
      CFRelease(actualUID);
    }
    return false;
  }
  CFStringRef expected = CFStringCreateWithCString(
      kCFAllocatorDefault, expectedUID, kCFStringEncodingUTF8);
  const bool matches = expected != NULL && CFEqual(actualUID, expected);
  if (expected != NULL) {
    CFRelease(expected);
  }
  CFRelease(actualUID);
  return matches;
}

static bool SnapshotSchemaIsExact(const OSVADiagnosticSnapshot *snapshot) {
  return snapshot != NULL &&
         snapshot->schema_version == kOSVADiagnosticSnapshotSchemaVersion &&
         snapshot->struct_size == sizeof(*snapshot) &&
         snapshot->client_slot_capacity ==
             kOSVADiagnosticClientSlotCapacity;
}

static SnapshotReadResult ResultForPropertyStatus(OSStatus status) {
  if (status == noErr) {
    return kSnapshotReadOK;
  }
  if (status == kAudioHardwareUnknownPropertyError) {
    return kSnapshotReadUnavailable;
  }
  if (status == kOSVADiagnosticSnapshotUnavailableError) {
    return kSnapshotReadRetry;
  }
  return kSnapshotReadFailed;
}

static SnapshotReadResult EvaluateCustomPropertyDeclarations(
    const AudioServerPlugInCustomPropertyInfo *info, size_t count) {
  if (info == NULL || count == 0) {
    return kSnapshotReadUnavailable;
  }
  bool found = false;
  for (size_t index = 0; index < count; ++index) {
    if (info[index].mSelector != kOSVADiagnosticSnapshotProperty) {
      continue;
    }
    if (found ||
        info[index].mPropertyDataType !=
            kAudioServerPlugInCustomPropertyDataTypeCFPropertyList ||
        info[index].mQualifierDataType !=
            kAudioServerPlugInCustomPropertyDataTypeNone) {
      return kSnapshotReadSchemaMismatch;
    }
    found = true;
  }
  return found ? kSnapshotReadOK : kSnapshotReadUnavailable;
}

static SnapshotReadResult
ValidateCustomPropertyDeclaration(AudioDeviceID deviceID,
                                  OSStatus *statusOut) {
  enum { kMaximumCustomPropertyCount = 32 };
  if (statusOut == NULL) {
    return kSnapshotReadFailed;
  }
  *statusOut = noErr;
  AudioObjectPropertyAddress address =
      PropertyAddress(kAudioObjectPropertyCustomPropertyInfoList);
  UInt32 size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL,
                                                   &size);
  if (status != noErr) {
    *statusOut = status;
    return ResultForPropertyStatus(status);
  }
  if (size == 0 || size > kMaximumCustomPropertyCount *
                             (UInt32)sizeof(AudioServerPlugInCustomPropertyInfo) ||
      size % sizeof(AudioServerPlugInCustomPropertyInfo) != 0) {
    return kSnapshotReadSchemaMismatch;
  }

  AudioServerPlugInCustomPropertyInfo info[kMaximumCustomPropertyCount];
  memset(info, 0, sizeof(info));
  UInt32 returnedSize = size;
  status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL,
                                      &returnedSize, info);
  if (status != noErr) {
    *statusOut = status;
    return ResultForPropertyStatus(status);
  }
  if (returnedSize != size ||
      returnedSize % sizeof(AudioServerPlugInCustomPropertyInfo) != 0) {
    return kSnapshotReadSchemaMismatch;
  }
  const size_t count =
      (size_t)returnedSize / sizeof(AudioServerPlugInCustomPropertyInfo);
  return EvaluateCustomPropertyDeclarations(info, count);
}

static SnapshotReadResult
DecodeSnapshotPropertyList(CFPropertyListRef propertyList,
                           OSVADiagnosticSnapshot *snapshot) {
  if (snapshot == NULL) {
    return kSnapshotReadFailed;
  }
  memset(snapshot, 0, sizeof(*snapshot));
  if (propertyList == NULL ||
      CFGetTypeID(propertyList) != CFDataGetTypeID()) {
    return kSnapshotReadSchemaMismatch;
  }
  CFDataRef data = (CFDataRef)propertyList;
  const CFIndex byteCount = CFDataGetLength(data);
  if (byteCount != (CFIndex)sizeof(*snapshot)) {
    return kSnapshotReadSchemaMismatch;
  }
  CFDataGetBytes(data, CFRangeMake(0, byteCount), (UInt8 *)snapshot);
  if (!SnapshotSchemaIsExact(snapshot)) {
    memset(snapshot, 0, sizeof(*snapshot));
    return kSnapshotReadSchemaMismatch;
  }
  return kSnapshotReadOK;
}

static SnapshotReadResult ReadSnapshot(AudioDeviceID deviceID,
                                       OSVADiagnosticSnapshot *snapshot,
                                       OSStatus *statusOut) {
  if (snapshot == NULL || statusOut == NULL) {
    return kSnapshotReadFailed;
  }
  *statusOut = noErr;
  AudioObjectPropertyAddress address =
      PropertyAddress(kOSVADiagnosticSnapshotProperty);
  UInt32 size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL,
                                                   &size);
  if (status != noErr) {
    *statusOut = status;
    return ResultForPropertyStatus(status);
  }
  if (size != sizeof(CFPropertyListRef)) {
    return kSnapshotReadSchemaMismatch;
  }

  CFPropertyListRef propertyList = NULL;
  UInt32 returnedSize = size;
  status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL,
                                      &returnedSize, &propertyList);
  if (status != noErr) {
    *statusOut = status;
    return ResultForPropertyStatus(status);
  }
  if (returnedSize != sizeof(propertyList)) {
    if (propertyList != NULL) {
      CFRelease(propertyList);
    }
    return kSnapshotReadSchemaMismatch;
  }
  SnapshotReadResult result =
      DecodeSnapshotPropertyList(propertyList, snapshot);
  if (propertyList != NULL) {
    CFRelease(propertyList);
  }
  return result;
}

static bool TransitionEqual(const OSVADiagnosticTransitionSnapshot *left,
                            const OSVADiagnosticTransitionSnapshot *right) {
  return left->host_ticks == right->host_ticks &&
         left->client_id == right->client_id &&
         left->pre_global_active_count == right->pre_global_active_count &&
         left->post_global_active_count == right->post_global_active_count &&
         left->driver_client_generation == right->driver_client_generation &&
         left->core_session_id == right->core_session_id &&
         left->reserved == right->reserved &&
         left->type == right->type &&
         left->endpoint_role == right->endpoint_role &&
         left->slot_index == right->slot_index &&
         left->process_id == right->process_id;
}

static bool
DriverSlotEqual(const OSVADiagnosticDriverClientSlotSnapshot *left,
                const OSVADiagnosticDriverClientSlotSnapshot *right) {
  return left->generation == right->generation &&
         left->registration_host_ticks == right->registration_host_ticks &&
         left->start_host_ticks == right->start_host_ticks &&
         left->last_transition_host_ticks == right->last_transition_host_ticks &&
         left->lease_session_id == right->lease_session_id &&
         left->lease_timeline_seed == right->lease_timeline_seed &&
         left->flags == right->flags &&
         left->device_object_id == right->device_object_id &&
         left->client_id == right->client_id &&
         left->process_id == right->process_id &&
         left->endpoint_role == right->endpoint_role &&
         left->core_client_slot == right->core_client_slot &&
         left->io_start_depth == right->io_start_depth &&
         left->reserved == right->reserved;
}

static bool CoreSlotEqual(const OSVADiagnosticCoreClientSlotSnapshot *left,
                          const OSVADiagnosticCoreClientSlotSnapshot *right) {
  return left->session_id == right->session_id &&
         left->client_id == right->client_id &&
         left->timeline_seed == right->timeline_seed &&
         left->endpoint_role == right->endpoint_role &&
         left->reserved == right->reserved;
}

/*
 * Observation sequence/time and the two real-time records may legitimately
 * advance between endpoint reads. Everything below is shared lifecycle state
 * and must agree when both lifecycle sequence numbers remain unchanged.
 */
static bool SharedStateEqual(const OSVADiagnosticSnapshot *left,
                             const OSVADiagnosticSnapshot *right) {
  if (!SnapshotSchemaIsExact(left) || !SnapshotSchemaIsExact(right) ||
      left->driver_instance_generation != right->driver_instance_generation ||
      left->invariant_flags != right->invariant_flags ||
      left->driver_lifecycle_sequence != right->driver_lifecycle_sequence ||
      left->core_lifecycle_sequence != right->core_lifecycle_sequence ||
      left->host_ticks_per_second != right->host_ticks_per_second ||
      left->timeline_seed != right->timeline_seed ||
      left->current_seed_generation != right->current_seed_generation ||
      left->anchor_host_ticks != right->anchor_host_ticks ||
      left->last_issued_seed != right->last_issued_seed ||
      left->last_issued_session_id != right->last_issued_session_id ||
      left->active_client_count != right->active_client_count ||
      left->visible_input_active_count !=
          right->visible_input_active_count ||
      left->hidden_writer_active_count !=
          right->hidden_writer_active_count ||
      left->core_active_slot_count != right->core_active_slot_count ||
      left->core_active_slot_bitmap != right->core_active_slot_bitmap ||
      left->driver_registered_count != right->driver_registered_count ||
      left->driver_started_count != right->driver_started_count ||
      left->visible_driver_registered_count !=
          right->visible_driver_registered_count ||
      left->hidden_driver_registered_count !=
          right->hidden_driver_registered_count ||
      left->visible_driver_started_count !=
          right->visible_driver_started_count ||
      left->hidden_driver_started_count !=
          right->hidden_driver_started_count ||
      left->driver_registered_slot_bitmap !=
          right->driver_registered_slot_bitmap ||
      left->driver_started_slot_bitmap != right->driver_started_slot_bitmap ||
      left->driver_client_add_attempt_count !=
          right->driver_client_add_attempt_count ||
      left->driver_client_add_count != right->driver_client_add_count ||
      left->driver_client_remove_attempt_count !=
          right->driver_client_remove_attempt_count ||
      left->driver_client_remove_count != right->driver_client_remove_count ||
      left->global_start_attempt_count != right->global_start_attempt_count ||
      left->global_start_transition_count !=
          right->global_start_transition_count ||
      left->global_stop_attempt_count != right->global_stop_attempt_count ||
      left->global_stop_transition_count !=
          right->global_stop_transition_count ||
      left->seed_create_count != right->seed_create_count ||
      left->seed_clear_count != right->seed_clear_count ||
      left->last_seed_create_host_ticks !=
          right->last_seed_create_host_ticks ||
      left->last_seed_clear_host_ticks !=
          right->last_seed_clear_host_ticks ||
      left->last_cleared_seed != right->last_cleared_seed ||
      left->last_cleared_seed_generation !=
          right->last_cleared_seed_generation ||
      left->last_cleared_anchor_host_ticks !=
          right->last_cleared_anchor_host_ticks ||
      left->reserved_header != right->reserved_header ||
      !TransitionEqual(&left->last_driver_transition,
                       &right->last_driver_transition) ||
      !TransitionEqual(&left->last_core_transition,
                       &right->last_core_transition) ||
      memcmp(left->reserved, right->reserved, sizeof(left->reserved)) != 0) {
    return false;
  }
  for (size_t index = 0; index < kOSVADiagnosticClientSlotCapacity; ++index) {
    if (!DriverSlotEqual(&left->driver_client_slots[index],
                         &right->driver_client_slots[index]) ||
        !CoreSlotEqual(&left->core_client_slots[index],
                       &right->core_client_slots[index])) {
      return false;
    }
  }
  return true;
}

static bool ExactTranslationsRemainStable(AudioDeviceID visibleDevice,
                                          AudioDeviceID writerDevice) {
  AudioDeviceID freshVisible = kAudioObjectUnknown;
  AudioDeviceID freshWriter = kAudioObjectUnknown;
  return TranslateExactDeviceUID(OSVA_VISIBLE_INPUT_DEVICE_UID,
                                 &freshVisible) == noErr &&
         TranslateExactDeviceUID(OSVA_HIDDEN_WRITER_DEVICE_UID, &freshWriter) ==
             noErr &&
         freshVisible == visibleDevice && freshWriter == writerDevice &&
         DeviceUIDMatches(freshVisible, OSVA_VISIBLE_INPUT_DEVICE_UID) &&
         DeviceUIDMatches(freshWriter, OSVA_HIDDEN_WRITER_DEVICE_UID);
}

static const char *BooleanJSON(bool value) { return value ? "true" : "false"; }

static void PrintTransition(const OSVADiagnosticTransitionSnapshot *value) {
  printf("{\"hostTicks\":%" PRIu64 ",\"clientID\":%" PRIu64
         ",\"preGlobalActiveCount\":%" PRIu64
         ",\"postGlobalActiveCount\":%" PRIu64
         ",\"driverClientGeneration\":%" PRIu64
         ",\"coreSessionID\":%" PRIu64
         ",\"type\":%" PRIu32 ",\"endpointRole\":%" PRIu32
         ",\"slotIndex\":%" PRIu32 ",\"processID\":%" PRId32 "}",
         value->host_ticks, value->client_id,
         value->pre_global_active_count, value->post_global_active_count,
         value->driver_client_generation, value->core_session_id, value->type,
         value->endpoint_role, value->slot_index, value->process_id);
}

static void PrintZeroTimestamp(const OSVADiagnosticZeroTimestampSnapshot *value,
                               UInt32 endpointRole) {
  printf("{\"endpointRole\":%" PRIu32 ",\"sequence\":%" PRIu64
         ",\"metadataSequence\":%" PRIu64
         ",\"metadataDroppedUpdateCount\":%" PRIu64
         ",\"epochMappingUnavailableCount\":%" PRIu64
         ",\"callCount\":%" PRIu64
         ",\"successfulReturnCount\":%" PRIu64
         ",\"fallbackReturnCount\":%" PRIu64
         ",\"failedReturnCount\":%" PRIu64
         ",\"lastCallHostTicks\":%" PRIu64
         ",\"lastSampleFrame\":%" PRIu64
         ",\"lastHostTicks\":%" PRIu64 ",\"lastSeed\":%" PRIu64
         ",\"lastSeedGeneration\":%" PRIu64
         ",\"lastCoreLifecycleSequence\":%" PRIu64
         ",\"lastCallCoreLifecycleSequence\":%" PRIu64
         ",\"lastClientID\":%" PRIu32 ",\"lastStatus\":%" PRId32
         ",\"flags\":%" PRIu32 "}",
         endpointRole, value->sequence, value->metadata_sequence,
         value->metadata_dropped_update_count,
         value->epoch_mapping_unavailable_count, value->call_count,
         value->successful_return_count, value->fallback_return_count,
         value->failed_return_count, value->last_call_host_ticks,
         value->last_sample_frame, value->last_host_ticks, value->last_seed,
         value->last_seed_generation,
         value->last_core_lifecycle_sequence,
         value->last_call_core_lifecycle_sequence, value->last_client_id,
         value->last_status, value->flags);
}

static void PrintIO(const OSVADiagnosticIOSnapshot *value,
                    UInt32 endpointRole) {
  printf("{\"endpointRole\":%" PRIu32 ",\"sequence\":%" PRIu64
         ",\"metadataSequence\":%" PRIu64
         ",\"metadataDroppedUpdateCount\":%" PRIu64
         ",\"operationCallCount\":%" PRIu64
         ",\"validCycleCount\":%" PRIu64
         ",\"invalidCycleCount\":%" PRIu64
         ",\"leaseUnavailableCount\":%" PRIu64
         ",\"epochMappingUnavailableCount\":%" PRIu64
         ",\"coreOKCount\":%" PRIu64 ",\"coreRetryCount\":%" PRIu64
         ",\"coreFailureCount\":%" PRIu64
         ",\"requestedFrameCount\":%" PRIu64
         ",\"transferredFrameCount\":%" PRIu64
         ",\"gapFrameCount\":%" PRIu64
         ",\"lastCycleSampleFrame\":%" PRIu64
         ",\"lastCycleHostTicks\":%" PRIu64
         ",\"lastPublishedFrameSeed\":%" PRIu64
         ",\"lastPublishedSeedGeneration\":%" PRIu64
         ",\"lastPublishedFrameSession\":%" PRIu64
         ",\"lastPublishedAbsoluteFrame\":%" PRIu64
         ",\"lastConsumedFrameSeed\":%" PRIu64
         ",\"lastConsumedSeedGeneration\":%" PRIu64
         ",\"lastConsumedFrameSession\":%" PRIu64
         ",\"lastConsumedAbsoluteFrame\":%" PRIu64
         ",\"lastClientID\":%" PRIu32 ",\"lastStatus\":%" PRId32
         ",\"flags\":%" PRIu32 "}",
         endpointRole, value->sequence, value->metadata_sequence,
         value->metadata_dropped_update_count,
         value->operation_call_count,
         value->valid_cycle_count, value->invalid_cycle_count,
         value->lease_unavailable_count,
         value->epoch_mapping_unavailable_count, value->core_ok_count,
         value->core_retry_count, value->core_failure_count,
         value->requested_frame_count, value->transferred_frame_count,
         value->gap_frame_count, value->last_cycle_sample_frame,
         value->last_cycle_host_ticks, value->last_published_frame_seed,
         value->last_published_seed_generation,
         value->last_published_frame_session,
         value->last_published_absolute_frame,
         value->last_consumed_frame_seed,
         value->last_consumed_seed_generation,
         value->last_consumed_frame_session,
         value->last_consumed_absolute_frame,
         value->last_client_id, value->last_status, value->flags);
}

static void
PrintIOWorkLoop(const OSVADiagnosticIOWorkLoopSnapshot *value,
                UInt32 endpointRole) {
  printf("{\"endpointRole\":%" PRIu32 ",\"sequence\":%" PRIu64
         ",\"metadataSequence\":%" PRIu64
         ",\"metadataDroppedUpdateCount\":%" PRIu64
         ",\"currentCount\":%" PRIu64 ",\"beginCount\":%" PRIu64
         ",\"endCount\":%" PRIu64 ",\"underflowCount\":%" PRIu64
         ",\"lastTransitionHostTicks\":%" PRIu64
         ",\"lastClientID\":%" PRIu32 ",\"flags\":%" PRIu32 "}",
         endpointRole, value->sequence, value->metadata_sequence,
         value->metadata_dropped_update_count,
         value->current_count, value->begin_count, value->end_count,
         value->underflow_count, value->last_transition_host_ticks,
         value->last_client_id, value->flags);
}

static void PrintDriverSlots(const OSVADiagnosticSnapshot *snapshot) {
  putchar('[');
  bool needsComma = false;
  for (UInt32 index = 0; index < snapshot->client_slot_capacity; ++index) {
    const OSVADiagnosticDriverClientSlotSnapshot *slot =
        &snapshot->driver_client_slots[index];
    if (slot->flags == 0 && slot->generation == 0 && slot->client_id == 0 &&
        slot->lease_session_id == 0) {
      continue;
    }
    if (needsComma) {
      putchar(',');
    }
    needsComma = true;
    printf("{\"slotIndex\":%" PRIu32 ",\"generation\":%" PRIu64
           ",\"registrationHostTicks\":%" PRIu64
           ",\"startHostTicks\":%" PRIu64
           ",\"lastTransitionHostTicks\":%" PRIu64
           ",\"leaseSessionID\":%" PRIu64
           ",\"leaseTimelineSeed\":%" PRIu64
           ",\"flags\":%" PRIu32 ",\"deviceObjectID\":%" PRIu32
           ",\"clientID\":%" PRIu32 ",\"processID\":%" PRId32
           ",\"endpointRole\":%" PRIu32
           ",\"coreClientSlot\":%" PRIu32
           ",\"ioStartDepth\":%" PRIu32 "}",
           index, slot->generation, slot->registration_host_ticks,
           slot->start_host_ticks, slot->last_transition_host_ticks,
           slot->lease_session_id,
           slot->lease_timeline_seed, slot->flags, slot->device_object_id,
           slot->client_id, slot->process_id, slot->endpoint_role,
           slot->core_client_slot, slot->io_start_depth);
  }
  putchar(']');
}

static void PrintCoreSlots(const OSVADiagnosticSnapshot *snapshot) {
  putchar('[');
  bool needsComma = false;
  for (UInt32 index = 0; index < snapshot->client_slot_capacity; ++index) {
    const OSVADiagnosticCoreClientSlotSnapshot *slot =
        &snapshot->core_client_slots[index];
    if (slot->session_id == 0 && slot->client_id == 0 &&
        slot->timeline_seed == 0 && slot->endpoint_role == 0) {
      continue;
    }
    if (needsComma) {
      putchar(',');
    }
    needsComma = true;
    printf("{\"slotIndex\":%" PRIu32 ",\"sessionID\":%" PRIu64
           ",\"clientID\":%" PRIu64 ",\"timelineSeed\":%" PRIu64
           ",\"endpointRole\":%" PRIu32 "}",
           index, slot->session_id, slot->client_id, slot->timeline_seed,
           slot->endpoint_role);
  }
  putchar(']');
}

static void PrintSnapshotJSON(
    AudioDeviceID visibleDevice, AudioDeviceID writerDevice,
    const char *mode,
    const EndpointObservation *visibleFirst,
    const EndpointObservation *writerObservation,
    const EndpointObservation *visibleFinal,
    const OSVADiagnosticSnapshot *snapshot) {
  const UInt64 requiredInvariantMask =
      kOSVADiagnosticInvariantGlobalMatchesCoreSlots |
      kOSVADiagnosticInvariantEndpointsMatchCoreSlots |
      kOSVADiagnosticInvariantDriverStartsMatchCoreSlots |
      kOSVADiagnosticInvariantIdleImpliesClockCleared |
      kOSVADiagnosticInvariantActiveImpliesClockValid |
      kOSVADiagnosticInvariantSlotCountsWithinCapacity |
      kOSVADiagnosticInvariantStartStopBalancedAtIdle |
      kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle |
      kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed |
      kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration;
  const bool allInvariantsHold =
      (snapshot->invariant_flags & requiredInvariantMask) ==
      requiredInvariantMask;

  printf("{\"readerSchema\":%d,\"mode\":\"%s\",\"claim\":"
         "\"read-only-virtual-driver-diagnostic-snapshot\","
         "\"visibleDeviceUID\":\"%s\",\"visibleDeviceID\":%" PRIu32
         ",\"writerDeviceUID\":\"%s\",\"writerDeviceID\":%" PRIu32
         ",\"customPropertyDataType\":\"CFPropertyList\","
         "\"payloadConcreteType\":\"CFData\","
         "\"endpointReadsCoherent\":true,"
         "\"observations\":{\"visibleFirst\":{\"snapshotSequence\":%" PRIu64
         ",\"capturedHostTicks\":%" PRIu64
         "},\"writer\":{\"snapshotSequence\":%" PRIu64
         ",\"capturedHostTicks\":%" PRIu64
         "},\"visibleFinal\":{\"snapshotSequence\":%" PRIu64
         ",\"capturedHostTicks\":%" PRIu64 "}},"
         "\"snapshotSchemaVersion\":%" PRIu32
         ",\"snapshotStructSize\":%" PRIu32
         ",\"driverInstanceGeneration\":%" PRIu64
         ",\"invariantFlags\":\"%016" PRIx64 "\","
         "\"allDeclaredInvariantsHold\":%s,"
         "\"coreInitialized\":%s,\"timelineActive\":%s,"
         "\"driverLifecycleSequence\":%" PRIu64
         ",\"coreLifecycleSequence\":%" PRIu64
         ",\"hostTicksPerSecond\":%" PRIu64
         ",\"timelineSeed\":%" PRIu64
         ",\"currentSeedGeneration\":%" PRIu64
         ",\"anchorHostTicks\":%" PRIu64
         ",\"lastIssuedSeed\":%" PRIu64
         ",\"lastIssuedSessionID\":%" PRIu64
         ",\"activeClientCount\":%" PRIu64
         ",\"visibleInputActiveCount\":%" PRIu64
         ",\"hiddenWriterActiveCount\":%" PRIu64
         ",\"coreActiveSlotCount\":%" PRIu64
         ",\"coreActiveSlotBitmap\":\"%016" PRIx64 "\","
         "\"driverRegisteredCount\":%" PRIu64
         ",\"driverStartedCount\":%" PRIu64
         ",\"visibleDriverRegisteredCount\":%" PRIu64
         ",\"hiddenDriverRegisteredCount\":%" PRIu64
         ",\"visibleDriverStartedCount\":%" PRIu64
         ",\"hiddenDriverStartedCount\":%" PRIu64
         ",\"driverRegisteredSlotBitmap\":\"%016" PRIx64 "\","
         "\"driverStartedSlotBitmap\":\"%016" PRIx64 "\","
         "\"driverClientAddAttemptCount\":%" PRIu64
         ",\"driverClientAddCount\":%" PRIu64
         ",\"driverClientRemoveAttemptCount\":%" PRIu64
         ",\"driverClientRemoveCount\":%" PRIu64
         ",\"globalStartAttemptCount\":%" PRIu64
         ",\"globalStartTransitionCount\":%" PRIu64
         ",\"globalStopAttemptCount\":%" PRIu64
         ",\"globalStopTransitionCount\":%" PRIu64
         ",\"seedCreateCount\":%" PRIu64
         ",\"seedClearCount\":%" PRIu64
         ",\"lastSeedCreateHostTicks\":%" PRIu64
         ",\"lastSeedClearHostTicks\":%" PRIu64
         ",\"lastClearedSeed\":%" PRIu64
         ",\"lastClearedSeedGeneration\":%" PRIu64
         ",\"lastClearedAnchorHostTicks\":%" PRIu64
         ",\"clientSlotCapacity\":%" PRIu32 ",\"lastDriverTransition\":",
         kReaderSchemaVersion, mode, OSVA_VISIBLE_INPUT_DEVICE_UID,
         visibleDevice,
         OSVA_HIDDEN_WRITER_DEVICE_UID, writerDevice,
         visibleFirst->snapshot_sequence, visibleFirst->captured_host_ticks,
         writerObservation->snapshot_sequence,
         writerObservation->captured_host_ticks, visibleFinal->snapshot_sequence,
         visibleFinal->captured_host_ticks, snapshot->schema_version,
         snapshot->struct_size, snapshot->driver_instance_generation,
         snapshot->invariant_flags, BooleanJSON(allInvariantsHold),
         BooleanJSON((snapshot->invariant_flags &
                      kOSVADiagnosticSnapshotCoreInitialized) != 0),
         BooleanJSON((snapshot->invariant_flags &
                      kOSVADiagnosticSnapshotTimelineActive) != 0),
         snapshot->driver_lifecycle_sequence,
         snapshot->core_lifecycle_sequence, snapshot->host_ticks_per_second,
         snapshot->timeline_seed, snapshot->current_seed_generation,
         snapshot->anchor_host_ticks,
         snapshot->last_issued_seed, snapshot->last_issued_session_id,
         snapshot->active_client_count, snapshot->visible_input_active_count,
         snapshot->hidden_writer_active_count,
         snapshot->core_active_slot_count, snapshot->core_active_slot_bitmap,
         snapshot->driver_registered_count, snapshot->driver_started_count,
         snapshot->visible_driver_registered_count,
         snapshot->hidden_driver_registered_count,
         snapshot->visible_driver_started_count,
         snapshot->hidden_driver_started_count,
         snapshot->driver_registered_slot_bitmap,
         snapshot->driver_started_slot_bitmap,
         snapshot->driver_client_add_attempt_count,
         snapshot->driver_client_add_count,
         snapshot->driver_client_remove_attempt_count,
         snapshot->driver_client_remove_count,
         snapshot->global_start_attempt_count,
         snapshot->global_start_transition_count,
         snapshot->global_stop_attempt_count,
         snapshot->global_stop_transition_count, snapshot->seed_create_count,
         snapshot->seed_clear_count, snapshot->last_seed_create_host_ticks,
         snapshot->last_seed_clear_host_ticks, snapshot->last_cleared_seed,
         snapshot->last_cleared_seed_generation,
         snapshot->last_cleared_anchor_host_ticks,
         snapshot->client_slot_capacity);
  PrintTransition(&snapshot->last_driver_transition);
  printf(",\"lastCoreTransition\":");
  PrintTransition(&snapshot->last_core_transition);
  printf(",\"zeroTimestamp\":[");
  PrintZeroTimestamp(&snapshot->zero_timestamp[0],
                     kOSVADiagnosticEndpointVisibleInput);
  putchar(',');
  PrintZeroTimestamp(&snapshot->zero_timestamp[1],
                     kOSVADiagnosticEndpointHiddenWriter);
  printf("],\"io\":[");
  PrintIO(&snapshot->io[0], kOSVADiagnosticEndpointVisibleInput);
  putchar(',');
  PrintIO(&snapshot->io[1], kOSVADiagnosticEndpointHiddenWriter);
  printf("],\"ioWorkLoop\":[");
  PrintIOWorkLoop(&snapshot->io_work_loop[0],
                  kOSVADiagnosticEndpointVisibleInput);
  putchar(',');
  PrintIOWorkLoop(&snapshot->io_work_loop[1],
                  kOSVADiagnosticEndpointHiddenWriter);
  printf("],\"driverClientSlots\":");
  PrintDriverSlots(snapshot);
  printf(",\"coreClientSlots\":");
  PrintCoreSlots(snapshot);
  puts("}");
}

static int ExitCodeForReadFailure(SnapshotReadResult result) {
  switch (result) {
  case kSnapshotReadSchemaMismatch:
    return kExitSchemaMismatch;
  case kSnapshotReadUnavailable:
    return kExitPropertyUnavailable;
  case kSnapshotReadRetry:
    return kExitRetry;
  default:
    return kExitInternalError;
  }
}

static int PrintReadFailure(const char *endpoint, SnapshotReadResult result,
                            OSStatus status) {
  if (result == kSnapshotReadSchemaMismatch) {
    fprintf(stderr, "%s diagnostic property schema/size mismatch\n", endpoint);
    return ExitCodeForReadFailure(result);
  }
  if (result == kSnapshotReadUnavailable) {
    fprintf(stderr,
            "%s diagnostic property is unavailable; the loaded driver does "
            "not expose osDS schema v1\n",
            endpoint);
    return ExitCodeForReadFailure(result);
  }
  if (result == kSnapshotReadRetry) {
    fprintf(stderr, "%s diagnostic snapshot remained in transition\n",
            endpoint);
    return ExitCodeForReadFailure(result);
  }
  fprintf(stderr, "%s diagnostic property read failed with OSStatus %" PRId32
                  "\n",
          endpoint, status);
  return ExitCodeForReadFailure(result);
}

static int RunReader(void) {
  AudioDeviceID visibleDevice = kAudioObjectUnknown;
  AudioDeviceID writerDevice = kAudioObjectUnknown;
  OSStatus status =
      TranslateExactDeviceUID(OSVA_VISIBLE_INPUT_DEVICE_UID, &visibleDevice);
  if (status != noErr || visibleDevice == kAudioObjectUnknown) {
    fprintf(stderr, "exact visible-input UID translation failed with OSStatus "
                    "%" PRId32 "\n",
            status);
    return kExitPropertyUnavailable;
  }
  status =
      TranslateExactDeviceUID(OSVA_HIDDEN_WRITER_DEVICE_UID, &writerDevice);
  if (status != noErr || writerDevice == kAudioObjectUnknown) {
    fprintf(stderr, "exact hidden-writer UID translation failed with OSStatus "
                    "%" PRId32 "\n",
            status);
    return kExitPropertyUnavailable;
  }
  if (visibleDevice == writerDevice ||
      !DeviceUIDMatches(visibleDevice, OSVA_VISIBLE_INPUT_DEVICE_UID) ||
      !DeviceUIDMatches(writerDevice, OSVA_HIDDEN_WRITER_DEVICE_UID)) {
    fprintf(stderr, "translated virtual-microphone endpoint identity mismatch\n");
    return kExitPropertyUnavailable;
  }

  OSStatus declarationStatus = noErr;
  SnapshotReadResult declarationResult =
      ValidateCustomPropertyDeclaration(visibleDevice, &declarationStatus);
  if (declarationResult != kSnapshotReadOK) {
    return PrintReadFailure("visible-input custom-property declaration",
                            declarationResult, declarationStatus);
  }
  declarationResult =
      ValidateCustomPropertyDeclaration(writerDevice, &declarationStatus);
  if (declarationResult != kSnapshotReadOK) {
    return PrintReadFailure("hidden-writer custom-property declaration",
                            declarationResult, declarationStatus);
  }

  for (unsigned attempt = 0; attempt < kMaximumCoherenceAttempts; ++attempt) {
    OSVADiagnosticSnapshot visibleFirst;
    OSVADiagnosticSnapshot writer;
    OSVADiagnosticSnapshot visibleFinal;
    OSStatus readStatus = noErr;
    SnapshotReadResult result =
        ReadSnapshot(visibleDevice, &visibleFirst, &readStatus);
    if (result != kSnapshotReadOK) {
      if (result == kSnapshotReadRetry) {
        continue;
      }
      return PrintReadFailure("visible-input", result, readStatus);
    }
    result = ReadSnapshot(writerDevice, &writer, &readStatus);
    if (result != kSnapshotReadOK) {
      if (result == kSnapshotReadRetry) {
        continue;
      }
      return PrintReadFailure("hidden-writer", result, readStatus);
    }
    result = ReadSnapshot(visibleDevice, &visibleFinal, &readStatus);
    if (result != kSnapshotReadOK) {
      if (result == kSnapshotReadRetry) {
        continue;
      }
      return PrintReadFailure("visible-input", result, readStatus);
    }
    if (!SharedStateEqual(&visibleFirst, &writer) ||
        !SharedStateEqual(&writer, &visibleFinal) ||
        !ExactTranslationsRemainStable(visibleDevice, writerDevice)) {
      continue;
    }

    const EndpointObservation visibleFirstObservation = {
        .snapshot_sequence = visibleFirst.snapshot_sequence,
        .captured_host_ticks = visibleFirst.captured_host_ticks,
    };
    const EndpointObservation writerObservation = {
        .snapshot_sequence = writer.snapshot_sequence,
        .captured_host_ticks = writer.captured_host_ticks,
    };
    const EndpointObservation visibleFinalObservation = {
        .snapshot_sequence = visibleFinal.snapshot_sequence,
        .captured_host_ticks = visibleFinal.captured_host_ticks,
    };
    PrintSnapshotJSON(visibleDevice, writerDevice, "read-once",
                      &visibleFirstObservation, &writerObservation,
                      &visibleFinalObservation,
                      &visibleFinal);
    return 0;
  }

  fprintf(stderr,
          "diagnostic lifecycle changed throughout %d bounded coherence "
          "attempts; retry\n",
          kMaximumCoherenceAttempts);
  return kExitRetry;
}

static void InitializeSelfTestFixture(OSVADiagnosticSnapshot *snapshot) {
  memset(snapshot, 0, sizeof(*snapshot));
  snapshot->schema_version = kOSVADiagnosticSnapshotSchemaVersion;
  snapshot->struct_size = (UInt32)sizeof(*snapshot);
  snapshot->snapshot_sequence = 10;
  snapshot->captured_host_ticks = 20;
  snapshot->driver_instance_generation = 30;
  snapshot->invariant_flags =
      kOSVADiagnosticSnapshotCoreInitialized |
      kOSVADiagnosticInvariantGlobalMatchesCoreSlots |
      kOSVADiagnosticInvariantEndpointsMatchCoreSlots |
      kOSVADiagnosticInvariantDriverStartsMatchCoreSlots |
      kOSVADiagnosticInvariantIdleImpliesClockCleared |
      kOSVADiagnosticInvariantActiveImpliesClockValid |
      kOSVADiagnosticInvariantSlotCountsWithinCapacity |
      kOSVADiagnosticInvariantStartStopBalancedAtIdle |
      kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle |
      kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed |
      kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration;
  snapshot->driver_lifecycle_sequence = 40;
  snapshot->core_lifecycle_sequence = 50;
  snapshot->host_ticks_per_second = UINT64_C(1000000000);
  snapshot->last_issued_seed = 3;
  snapshot->last_issued_session_id = 7;
  snapshot->seed_create_count = 3;
  snapshot->seed_clear_count = 3;
  snapshot->client_slot_capacity = kOSVADiagnosticClientSlotCapacity;
  snapshot->last_driver_transition = (OSVADiagnosticTransitionSnapshot){
      .host_ticks = 60,
      .client_id = 1001,
      .pre_global_active_count = 0,
      .post_global_active_count = 1,
      .driver_client_generation = 70,
      .core_session_id = 80,
      .type = kOSVADiagnosticTransitionIOStarted,
      .endpoint_role = kOSVADiagnosticEndpointVisibleInput,
      .slot_index = 4,
      .process_id = 4321,
  };
  snapshot->last_core_transition = snapshot->last_driver_transition;
  snapshot->zero_timestamp[0] = (OSVADiagnosticZeroTimestampSnapshot){
      .sequence = 4,
      .metadata_sequence = 2,
      .metadata_dropped_update_count = 3,
      .epoch_mapping_unavailable_count = 0,
      .call_count = 4,
      .successful_return_count = 3,
      .failed_return_count = 1,
      .last_call_host_ticks = 90,
      .last_sample_frame = 100,
      .last_host_ticks = 110,
      .last_seed = 3,
      .last_seed_generation = 3,
      .last_core_lifecycle_sequence = 48,
      .last_call_core_lifecycle_sequence = 50,
      .last_client_id = 1001,
      .last_status = 0,
      .flags = kOSVADiagnosticRecordPresent |
               kOSVADiagnosticRecordLastSuccessTupleValid |
               kOSVADiagnosticRecordLastCallValid |
               kOSVADiagnosticRecordEpochMappingValid,
  };
  snapshot->io[1] = (OSVADiagnosticIOSnapshot){
      .sequence = 6,
      .metadata_sequence = 2,
      .metadata_dropped_update_count = 5,
      .operation_call_count = 6,
      .valid_cycle_count = 6,
      .epoch_mapping_unavailable_count = 0,
      .core_ok_count = 6,
      .requested_frame_count = 24,
      .transferred_frame_count = 24,
      .last_cycle_sample_frame = 120,
      .last_cycle_host_ticks = 130,
      .last_published_frame_seed = 3,
      .last_published_seed_generation = 3,
      .last_published_frame_session = 7,
      .last_published_absolute_frame = 123,
      .last_client_id = 1002,
      .last_status = 0,
      .flags = kOSVADiagnosticRecordPresent |
               kOSVADiagnosticRecordLastSuccessTupleValid |
               kOSVADiagnosticRecordLastCallValid |
               kOSVADiagnosticRecordEpochMappingValid,
  };
  snapshot->io_work_loop[0] = (OSVADiagnosticIOWorkLoopSnapshot){
      .sequence = 9,
      .metadata_sequence = 2,
      .metadata_dropped_update_count = 8,
      .current_count = 2,
      .begin_count = 5,
      .end_count = 4,
      .underflow_count = 1,
      .last_transition_host_ticks = 140,
      .last_client_id = 1001,
      .flags = kOSVADiagnosticRecordPresent |
               kOSVADiagnosticRecordLastCallValid,
  };
}

static int RunSelfTest(void) {
  unsigned passed = 0;
  OSVADiagnosticSnapshot first;
  InitializeSelfTestFixture(&first);
  if (!SnapshotSchemaIsExact(&first)) {
    return 1;
  }
  passed += 1;

  OSVADiagnosticSnapshot changed = first;
  changed.schema_version += 1;
  if (SnapshotSchemaIsExact(&changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.struct_size -= 1;
  if (SnapshotSchemaIsExact(&changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.client_slot_capacity -= 1;
  if (SnapshotSchemaIsExact(&changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.snapshot_sequence += 1;
  changed.captured_host_ticks += 100;
  changed.zero_timestamp[0].metadata_dropped_update_count += 1;
  changed.zero_timestamp[0].call_count += 1;
  changed.zero_timestamp[0].last_call_core_lifecycle_sequence += 2;
  changed.io[1].metadata_dropped_update_count += 1;
  changed.io[1].operation_call_count += 1;
  changed.io[1].last_published_seed_generation += 1;
  changed.io[1].last_consumed_seed_generation += 1;
  changed.io_work_loop[0].metadata_dropped_update_count += 1;
  changed.io_work_loop[0].current_count += 1;
  if (!SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.last_driver_transition.driver_client_generation += 1;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.last_driver_transition.core_session_id += 1;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.last_driver_transition.process_id += 1;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.timeline_seed = 99;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.driver_client_slots[4].flags =
      kOSVADiagnosticDriverSlotRegistered;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  changed = first;
  changed.core_client_slots[2].session_id = 1;
  if (SharedStateEqual(&first, &changed)) {
    return 1;
  }
  passed += 1;

  if (ExitCodeForReadFailure(kSnapshotReadSchemaMismatch) !=
      kExitSchemaMismatch) {
    return 1;
  }
  passed += 1;
  if (ExitCodeForReadFailure(kSnapshotReadUnavailable) !=
      kExitPropertyUnavailable) {
    return 1;
  }
  passed += 1;
  if (ExitCodeForReadFailure(kSnapshotReadRetry) != kExitRetry) {
    return 1;
  }
  passed += 1;
  if (ExitCodeForReadFailure(kSnapshotReadFailed) != kExitInternalError) {
    return 1;
  }
  passed += 1;

  if (ResultForPropertyStatus(noErr) != kSnapshotReadOK) {
    return 1;
  }
  passed += 1;
  if (ResultForPropertyStatus(kAudioHardwareUnknownPropertyError) !=
      kSnapshotReadUnavailable) {
    return 1;
  }
  passed += 1;
  if (ResultForPropertyStatus(kOSVADiagnosticSnapshotUnavailableError) !=
      kSnapshotReadRetry) {
    return 1;
  }
  passed += 1;
  if (ResultForPropertyStatus(kAudioHardwareBadObjectError) !=
      kSnapshotReadFailed) {
    return 1;
  }
  passed += 1;

  const AudioServerPlugInCustomPropertyInfo exactDeclaration = {
      .mSelector = kOSVADiagnosticSnapshotProperty,
      .mPropertyDataType =
          kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
      .mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone,
  };
  if (EvaluateCustomPropertyDeclarations(&exactDeclaration, 1) !=
      kSnapshotReadOK) {
    return 1;
  }
  passed += 1;

  AudioServerPlugInCustomPropertyInfo wrongDeclaration = exactDeclaration;
  wrongDeclaration.mPropertyDataType =
      kAudioServerPlugInCustomPropertyDataTypeCFString;
  if (EvaluateCustomPropertyDeclarations(&wrongDeclaration, 1) !=
      kSnapshotReadSchemaMismatch) {
    return 1;
  }
  passed += 1;

  const AudioServerPlugInCustomPropertyInfo duplicateDeclarations[2] = {
      exactDeclaration,
      exactDeclaration,
  };
  if (EvaluateCustomPropertyDeclarations(duplicateDeclarations, 2) !=
      kSnapshotReadSchemaMismatch) {
    return 1;
  }
  passed += 1;

  wrongDeclaration = exactDeclaration;
  wrongDeclaration.mSelector = (AudioObjectPropertySelector)0x7A7A7A7A;
  if (EvaluateCustomPropertyDeclarations(&wrongDeclaration, 1) !=
      kSnapshotReadUnavailable) {
    return 1;
  }
  passed += 1;

  CFDataRef validData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&first,
                                     (CFIndex)sizeof(first));
  OSVADiagnosticSnapshot decoded;
  if (validData == NULL ||
      DecodeSnapshotPropertyList(validData, &decoded) != kSnapshotReadOK ||
      !SharedStateEqual(&first, &decoded)) {
    if (validData != NULL) {
      CFRelease(validData);
    }
    return 1;
  }
  CFRelease(validData);
  passed += 1;

  CFDataRef shortData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&first,
                                     (CFIndex)sizeof(first) - 1);
  if (shortData == NULL ||
      DecodeSnapshotPropertyList(shortData, &decoded) !=
          kSnapshotReadSchemaMismatch) {
    if (shortData != NULL) {
      CFRelease(shortData);
    }
    return 1;
  }
  CFRelease(shortData);
  passed += 1;

  CFStringRef wrongConcreteType = CFSTR("not snapshot bytes");
  if (DecodeSnapshotPropertyList(wrongConcreteType, &decoded) !=
      kSnapshotReadSchemaMismatch) {
    return 1;
  }
  passed += 1;

  OSVADiagnosticSnapshot wrongSchema = first;
  wrongSchema.schema_version += 1;
  CFDataRef wrongSchemaData =
      CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&wrongSchema,
                   (CFIndex)sizeof(wrongSchema));
  if (wrongSchemaData == NULL ||
      DecodeSnapshotPropertyList(wrongSchemaData, &decoded) !=
          kSnapshotReadSchemaMismatch) {
    if (wrongSchemaData != NULL) {
      CFRelease(wrongSchemaData);
    }
    return 1;
  }
  CFRelease(wrongSchemaData);
  passed += 1;

  const EndpointObservation firstObservation = {
      .snapshot_sequence = first.snapshot_sequence,
      .captured_host_ticks = first.captured_host_ticks,
  };
  const EndpointObservation writerObservation = {
      .snapshot_sequence = first.snapshot_sequence + 1,
      .captured_host_ticks = first.captured_host_ticks + 1,
  };
  const EndpointObservation finalObservation = {
      .snapshot_sequence = first.snapshot_sequence + 2,
      .captured_host_ticks = first.captured_host_ticks + 2,
  };
  PrintSnapshotJSON(kOSVAObjectIDVisibleInputDevice,
                    kOSVAObjectIDHiddenWriterDevice, "self-test-fixture",
                    &firstObservation, &writerObservation, &finalObservation,
                    &first);

  printf("{\"schema\":1,\"mode\":\"self-test\",\"passed\":true,"
         "\"tests\":%u,\"coreAudioIOStarted\":false,"
         "\"routesMutated\":false}\n",
         passed);
  return 0;
}

int main(int argc, char *argv[]) {
  if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
    return RunSelfTest();
  }
  if (argc == 2 && strcmp(argv[1], "--read-once") == 0) {
    return RunReader();
  }
  fprintf(stderr, "usage: %s --self-test | --read-once\n", argv[0]);
  return kExitUsage;
}
