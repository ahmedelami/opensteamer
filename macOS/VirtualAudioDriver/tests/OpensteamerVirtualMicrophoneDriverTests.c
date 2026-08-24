#include "OpensteamerVirtualMicrophoneDriver.h"
#include "OpensteamerVirtualAudioCore.h"

#include <CoreAudio/AudioHardware.h>

#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);     \
      return false;                                                            \
    }                                                                          \
  } while (0)

#define CHECK_STATUS(actual, expected) CHECK((actual) == (expected))

typedef struct {
  UInt32 notificationCount;
  AudioObjectID lastObjectID;
  AudioObjectPropertyAddress lastAddress;
} FakeHostState;

static FakeHostState gFakeHostState;

static OSStatus
FakePropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID objectID,
                      UInt32 numberAddresses,
                      const AudioObjectPropertyAddress *addresses) {
  (void)host;
  gFakeHostState.notificationCount += 1;
  gFakeHostState.lastObjectID = objectID;
  if (numberAddresses > 0 && addresses != NULL) {
    gFakeHostState.lastAddress = addresses[0];
  }
  return noErr;
}

static OSStatus FakeCopyFromStorage(AudioServerPlugInHostRef host,
                                    CFStringRef key,
                                    CFPropertyListRef *outData) {
  (void)host;
  (void)key;
  if (outData != NULL) {
    *outData = NULL;
  }
  return noErr;
}

static OSStatus FakeWriteToStorage(AudioServerPlugInHostRef host,
                                   CFStringRef key, CFPropertyListRef data) {
  (void)host;
  (void)key;
  (void)data;
  return noErr;
}

static OSStatus FakeDeleteFromStorage(AudioServerPlugInHostRef host,
                                      CFStringRef key) {
  (void)host;
  (void)key;
  return noErr;
}

static OSStatus
FakeRequestDeviceConfigurationChange(AudioServerPlugInHostRef host,
                                     AudioObjectID deviceObjectID,
                                     UInt64 changeAction, void *changeInfo) {
  (void)host;
  (void)deviceObjectID;
  (void)changeAction;
  (void)changeInfo;
  return noErr;
}

static const AudioServerPlugInHostInterface gFakeHost = {
    .PropertiesChanged = FakePropertiesChanged,
    .CopyFromStorage = FakeCopyFromStorage,
    .WriteToStorage = FakeWriteToStorage,
    .DeleteFromStorage = FakeDeleteFromStorage,
    .RequestDeviceConfigurationChange = FakeRequestDeviceConfigurationChange,
};

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address = {
      .mSelector = selector,
      .mScope = scope,
      .mElement = kAudioObjectPropertyElementMain,
  };
  return address;
}

static AudioServerPlugInDriverRef FreshDriver(void) {
  AudioServerPlugInDriverRef driver = OpensteamerVirtualMicrophone_Create(
      kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
  if (driver == NULL) {
    return NULL;
  }
  if (OSVADriverResetForTesting() != noErr) {
    return NULL;
  }
  memset(&gFakeHostState, 0, sizeof(gFakeHostState));
  if ((*driver)->Initialize(driver, &gFakeHost) != noErr) {
    return NULL;
  }
  return driver;
}

static bool GetUInt32(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                      AudioObjectPropertyAddress address, UInt32 expected) {
  UInt32 value = UINT32_MAX;
  UInt32 size = 0;
  OSStatus status = (*driver)->GetPropertyData(
      driver, objectID, 0, &address, 0, NULL, sizeof(value), &size, &value);
  CHECK_STATUS(status, noErr);
  CHECK(size == sizeof(value));
  CHECK(value == expected);
  return true;
}

static bool GetFloat32(AudioServerPlugInDriverRef driver,
                       AudioObjectID objectID,
                       AudioObjectPropertyAddress address, Float32 expected) {
  Float32 value = NAN;
  UInt32 size = 0;
  OSStatus status = (*driver)->GetPropertyData(
      driver, objectID, 0, &address, 0, NULL, sizeof(value), &size, &value);
  CHECK_STATUS(status, noErr);
  CHECK(size == sizeof(value));
  CHECK(value == expected);
  return true;
}

static bool GetCFString(AudioServerPlugInDriverRef driver,
                        AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        CFStringRef expected) {
  CFStringRef value = NULL;
  UInt32 size = 0;
  OSStatus status = (*driver)->GetPropertyData(
      driver, objectID, 0, &address, 0, NULL, sizeof(value), &size, &value);
  CHECK_STATUS(status, noErr);
  CHECK(size == sizeof(value));
  CHECK(value != NULL);
  CHECK(CFEqual(value, expected));
  return true;
}

static UInt64 DiagnosticInvariantMask(void) {
  return kOSVADiagnosticInvariantGlobalMatchesCoreSlots |
         kOSVADiagnosticInvariantEndpointsMatchCoreSlots |
         kOSVADiagnosticInvariantDriverStartsMatchCoreSlots |
         kOSVADiagnosticInvariantIdleImpliesClockCleared |
         kOSVADiagnosticInvariantActiveImpliesClockValid |
         kOSVADiagnosticInvariantSlotCountsWithinCapacity |
         kOSVADiagnosticInvariantStartStopBalancedAtIdle |
         kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle |
         kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed |
         kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration;
}

static UInt64 PopCount64(UInt64 value) {
  UInt64 count = 0;
  while (value != 0) {
    count += value & UINT64_C(1);
    value >>= 1U;
  }
  return count;
}

static bool UInt64PairAbsoluteDifferenceWithin(UInt64 leftFirst,
                                               UInt64 leftSecond,
                                               UInt64 rightFirst,
                                               UInt64 rightSecond,
                                               UInt64 limit) {
  const UInt64 leftLow = leftFirst + leftSecond;
  const UInt64 leftHigh = leftLow < leftFirst ? UINT64_C(1) : UINT64_C(0);
  const UInt64 rightLow = rightFirst + rightSecond;
  const UInt64 rightHigh =
      rightLow < rightFirst ? UINT64_C(1) : UINT64_C(0);
  const bool leftIsLarger =
      leftHigh > rightHigh ||
      (leftHigh == rightHigh && leftLow >= rightLow);
  const UInt64 largerHigh = leftIsLarger ? leftHigh : rightHigh;
  const UInt64 largerLow = leftIsLarger ? leftLow : rightLow;
  const UInt64 smallerHigh = leftIsLarger ? rightHigh : leftHigh;
  const UInt64 smallerLow = leftIsLarger ? rightLow : leftLow;
  const UInt64 borrow = largerLow < smallerLow ? UINT64_C(1) : UINT64_C(0);
  const UInt64 differenceHigh = largerHigh - smallerHigh - borrow;
  const UInt64 differenceLow = largerLow - smallerLow;
  return differenceHigh == 0 && differenceLow <= limit;
}

static OSStatus CopyDiagnosticSnapshot(
    AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    OSVADiagnosticSnapshot *snapshotOut) {
  AudioObjectPropertyAddress address =
      Address(kOSVADiagnosticSnapshotProperty,
              kAudioObjectPropertyScopeGlobal);
  UInt32 size = 0;
  CFPropertyListRef property = NULL;
  memset(snapshotOut, 0xA5, sizeof(*snapshotOut));
  OSStatus status = (*driver)->GetPropertyData(
      driver, objectID, 0, &address, 0, NULL, (UInt32)sizeof(property), &size,
      &property);
  if (status != noErr) {
    return status;
  }
  if (size != sizeof(property) || property == NULL ||
      CFGetTypeID(property) != CFDataGetTypeID()) {
    if (property != NULL) {
      CFRelease(property);
    }
    return kAudioHardwareBadPropertySizeError;
  }
  CFDataRef data = (CFDataRef)property;
  if (CFDataGetLength(data) != (CFIndex)sizeof(*snapshotOut)) {
    CFRelease(property);
    return kAudioHardwareBadPropertySizeError;
  }
  CFDataGetBytes(data, CFRangeMake(0, CFDataGetLength(data)),
                 (UInt8 *)snapshotOut);
  CFRelease(property);
  return noErr;
}

static bool DiagnosticSnapshotIsCoherent(
    const OSVADiagnosticSnapshot *snapshot) {
  if (snapshot->schema_version != kOSVADiagnosticSnapshotSchemaVersion ||
      snapshot->struct_size != sizeof(*snapshot) ||
      snapshot->snapshot_sequence == 0 ||
      snapshot->captured_host_ticks == 0 ||
      snapshot->driver_instance_generation == 0 ||
      snapshot->host_ticks_per_second == 0 ||
      snapshot->client_slot_capacity != kOSVADiagnosticClientSlotCapacity ||
      (snapshot->invariant_flags &
       kOSVADiagnosticSnapshotCoreInitialized) == 0 ||
      (snapshot->invariant_flags & DiagnosticInvariantMask()) !=
          DiagnosticInvariantMask()) {
    return false;
  }

  if (snapshot->active_client_count != snapshot->core_active_slot_count ||
      snapshot->active_client_count !=
          snapshot->visible_input_active_count +
              snapshot->hidden_writer_active_count ||
      snapshot->active_client_count !=
          PopCount64(snapshot->core_active_slot_bitmap) ||
      snapshot->driver_registered_count !=
          PopCount64(snapshot->driver_registered_slot_bitmap) ||
      snapshot->driver_started_count !=
          PopCount64(snapshot->driver_started_slot_bitmap) ||
      snapshot->driver_started_count != snapshot->active_client_count ||
      snapshot->driver_registered_count !=
          snapshot->visible_driver_registered_count +
              snapshot->hidden_driver_registered_count ||
      snapshot->driver_started_count !=
          snapshot->visible_driver_started_count +
              snapshot->hidden_driver_started_count ||
      snapshot->visible_driver_started_count !=
          snapshot->visible_input_active_count ||
      snapshot->hidden_driver_started_count !=
          snapshot->hidden_writer_active_count ||
      snapshot->global_start_transition_count <
          snapshot->global_stop_transition_count ||
      snapshot->seed_create_count < snapshot->seed_clear_count) {
    return false;
  }

  const bool timelineActive =
      (snapshot->invariant_flags & kOSVADiagnosticSnapshotTimelineActive) != 0;
  if (snapshot->active_client_count == 0) {
    if (timelineActive || snapshot->timeline_seed != 0 ||
        snapshot->current_seed_generation != 0 ||
        snapshot->anchor_host_ticks != 0 ||
        snapshot->global_start_transition_count !=
            snapshot->global_stop_transition_count ||
        snapshot->seed_create_count != snapshot->seed_clear_count) {
      return false;
    }
  } else if (!timelineActive || snapshot->timeline_seed == 0 ||
             snapshot->current_seed_generation == 0 ||
             snapshot->current_seed_generation != snapshot->timeline_seed ||
             snapshot->anchor_host_ticks == 0 ||
             snapshot->global_start_transition_count -
                     snapshot->global_stop_transition_count !=
                 snapshot->active_client_count ||
             snapshot->seed_create_count - snapshot->seed_clear_count != 1) {
    return false;
  }
  if (snapshot->last_cleared_seed_generation !=
      snapshot->last_cleared_seed) {
    return false;
  }

  UInt64 registeredCount = 0;
  UInt64 startedCount = 0;
  UInt64 visibleRegisteredCount = 0;
  UInt64 hiddenRegisteredCount = 0;
  UInt64 visibleStartedCount = 0;
  UInt64 hiddenStartedCount = 0;
  UInt64 coreActiveCount = 0;
  for (UInt32 index = 0; index < kOSVADiagnosticClientSlotCapacity; ++index) {
    const UInt64 bit = UINT64_C(1) << index;
    const OSVADiagnosticDriverClientSlotSnapshot *driverSlot =
        &snapshot->driver_client_slots[index];
    const bool registered =
        (driverSlot->flags & kOSVADiagnosticDriverSlotRegistered) != 0;
    const bool started =
        (driverSlot->flags & kOSVADiagnosticDriverSlotStarted) != 0;
    const bool leaseValid =
        (driverSlot->flags & kOSVADiagnosticDriverSlotLeaseValid) != 0;
    if (registered !=
            ((snapshot->driver_registered_slot_bitmap & bit) != 0) ||
        started != ((snapshot->driver_started_slot_bitmap & bit) != 0) ||
        driverSlot->reserved != 0) {
      return false;
    }
    if (registered) {
      registeredCount += 1;
      if (driverSlot->generation == 0 ||
          driverSlot->registration_host_ticks == 0 ||
          driverSlot->last_transition_host_ticks == 0 ||
          driverSlot->client_id == 0 || driverSlot->process_id == 0 ||
          (driverSlot->endpoint_role != kOSVADiagnosticEndpointVisibleInput &&
           driverSlot->endpoint_role !=
               kOSVADiagnosticEndpointHiddenWriter)) {
        return false;
      }
      if (driverSlot->endpoint_role ==
          kOSVADiagnosticEndpointVisibleInput) {
        visibleRegisteredCount += 1;
      } else {
        hiddenRegisteredCount += 1;
      }
    }
    if (started) {
      startedCount += 1;
      if (!registered || !leaseValid || driverSlot->io_start_depth != 1 ||
          driverSlot->start_host_ticks == 0 ||
          driverSlot->lease_session_id == 0 ||
          driverSlot->lease_timeline_seed != snapshot->timeline_seed ||
          driverSlot->core_client_slot >=
              kOSVADiagnosticClientSlotCapacity) {
        return false;
      }
      if (driverSlot->endpoint_role ==
          kOSVADiagnosticEndpointVisibleInput) {
        visibleStartedCount += 1;
      } else {
        hiddenStartedCount += 1;
      }
      const OSVADiagnosticCoreClientSlotSnapshot *coreSlot =
          &snapshot->core_client_slots[driverSlot->core_client_slot];
      const UInt64 expectedCoreClientID =
          ((UInt64)driverSlot->device_object_id << 32U) |
          (UInt64)driverSlot->client_id;
      if (coreSlot->session_id != driverSlot->lease_session_id ||
          coreSlot->client_id != expectedCoreClientID ||
          coreSlot->timeline_seed != driverSlot->lease_timeline_seed ||
          coreSlot->endpoint_role != driverSlot->endpoint_role) {
        return false;
      }
    } else if (leaseValid || driverSlot->io_start_depth != 0) {
      return false;
    }

    const OSVADiagnosticCoreClientSlotSnapshot *coreSlot =
        &snapshot->core_client_slots[index];
    const bool coreActive = coreSlot->session_id != 0;
    if (coreActive != ((snapshot->core_active_slot_bitmap & bit) != 0) ||
        coreSlot->reserved != 0) {
      return false;
    }
    if (coreActive) {
      coreActiveCount += 1;
      if (coreSlot->client_id == 0 ||
          coreSlot->timeline_seed != snapshot->timeline_seed ||
          (coreSlot->endpoint_role != kOSVADiagnosticEndpointVisibleInput &&
           coreSlot->endpoint_role != kOSVADiagnosticEndpointHiddenWriter)) {
        return false;
      }
    }
  }
  if (registeredCount != snapshot->driver_registered_count ||
      startedCount != snapshot->driver_started_count ||
      visibleRegisteredCount != snapshot->visible_driver_registered_count ||
      hiddenRegisteredCount != snapshot->hidden_driver_registered_count ||
      visibleStartedCount != snapshot->visible_driver_started_count ||
      hiddenStartedCount != snapshot->hidden_driver_started_count ||
      coreActiveCount != snapshot->core_active_slot_count) {
    return false;
  }

  for (size_t index = 0; index < 2; ++index) {
    const OSVADiagnosticZeroTimestampSnapshot *zero =
        &snapshot->zero_timestamp[index];
    const OSVADiagnosticIOSnapshot *io = &snapshot->io[index];
    const OSVADiagnosticIOWorkLoopSnapshot *workLoop =
        &snapshot->io_work_loop[index];
    const UInt32 knownRecordFlags =
        kOSVADiagnosticRecordPresent |
        kOSVADiagnosticRecordLastSuccessTupleValid |
        kOSVADiagnosticRecordLastCallValid |
        kOSVADiagnosticRecordUsedFallback |
        kOSVADiagnosticRecordEpochMappingValid;
    if (zero->sequence != zero->call_count ||
        (zero->metadata_sequence & UINT64_C(1)) != 0 ||
        (zero->metadata_sequence / UINT64_C(2)) +
                zero->metadata_dropped_update_count !=
            zero->sequence ||
        zero->call_count !=
            zero->successful_return_count + zero->failed_return_count ||
        zero->fallback_return_count > zero->successful_return_count ||
        zero->epoch_mapping_unavailable_count != 0 ||
        (zero->flags & ~knownRecordFlags) != 0 || zero->reserved != 0 ||
        io->sequence != io->operation_call_count ||
        (io->metadata_sequence & UINT64_C(1)) != 0 ||
        (io->metadata_sequence / UINT64_C(2)) +
                io->metadata_dropped_update_count !=
            io->sequence ||
        io->operation_call_count !=
            io->valid_cycle_count + io->invalid_cycle_count ||
        io->epoch_mapping_unavailable_count != 0 ||
        (io->flags & ~knownRecordFlags) != 0 || io->reserved != 0) {
      return false;
    }
    if ((zero->flags & kOSVADiagnosticRecordPresent) != 0) {
      if (zero->metadata_sequence == 0 || zero->last_call_host_ticks == 0 ||
          zero->last_call_core_lifecycle_sequence == 0 ||
          zero->last_client_id == 0) {
        return false;
      }
    } else if (zero->metadata_sequence != 0) {
      return false;
    }
    if ((zero->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0) {
      if (zero->successful_return_count == 0 || zero->last_host_ticks == 0 ||
          zero->last_seed == 0 || zero->last_core_lifecycle_sequence == 0) {
        return false;
      }
      const bool mappingValid =
          (zero->flags & kOSVADiagnosticRecordEpochMappingValid) != 0;
      if (mappingValid != (zero->last_seed_generation != 0) ||
          (mappingValid &&
           zero->last_seed_generation != zero->last_seed)) {
        return false;
      }
    } else if ((zero->flags & (kOSVADiagnosticRecordUsedFallback |
                               kOSVADiagnosticRecordEpochMappingValid)) != 0) {
      return false;
    }
    if ((zero->flags & kOSVADiagnosticRecordUsedFallback) != 0 &&
        zero->fallback_return_count == 0) {
      return false;
    }
    if ((zero->flags & kOSVADiagnosticRecordLastCallValid) != 0 &&
        zero->last_status != 0) {
      return false;
    }
    if ((io->flags & kOSVADiagnosticRecordPresent) != 0) {
      if (io->metadata_sequence == 0 || io->last_cycle_host_ticks == 0 ||
          io->last_client_id == 0) {
        return false;
      }
    } else if (io->metadata_sequence != 0) {
      return false;
    }
    if ((io->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0) {
      const bool publishedTuple = io->last_published_frame_seed != 0 &&
                                  io->last_published_frame_session != 0;
      const bool consumedTuple = io->last_consumed_frame_seed != 0 &&
                                 io->last_consumed_frame_session != 0;
      if (publishedTuple == consumedTuple) {
        return false;
      }
      const UInt64 tupleGeneration = publishedTuple
                                         ? io->last_published_seed_generation
                                         : io->last_consumed_seed_generation;
      const bool mappingValid =
          (io->flags & kOSVADiagnosticRecordEpochMappingValid) != 0;
      const UInt64 tupleSeed = publishedTuple
                                   ? io->last_published_frame_seed
                                   : io->last_consumed_frame_seed;
      if (mappingValid != (tupleGeneration != 0) ||
          (mappingValid && tupleGeneration != tupleSeed)) {
        return false;
      }
    } else if ((io->flags & kOSVADiagnosticRecordEpochMappingValid) != 0) {
      return false;
    }
    if ((io->flags & kOSVADiagnosticRecordUsedFallback) != 0) {
      return false;
    }
    const UInt32 knownWorkLoopFlags = kOSVADiagnosticRecordPresent |
                                      kOSVADiagnosticRecordLastCallValid;
    const UInt64 successfulMetadataUpdates =
        workLoop->metadata_sequence / UINT64_C(2);
    const bool metadataAccountingCoversCallbacks =
        workLoop->metadata_dropped_update_count >= workLoop->sequence ||
        successfulMetadataUpdates >=
            workLoop->sequence - workLoop->metadata_dropped_update_count;
    const bool currentAccountingWithinDrops =
        UInt64PairAbsoluteDifferenceWithin(
            workLoop->begin_count, workLoop->underflow_count,
            workLoop->end_count, workLoop->current_count,
            workLoop->metadata_dropped_update_count);
    if ((workLoop->metadata_sequence & UINT64_C(1)) != 0 ||
        (workLoop->flags & ~knownWorkLoopFlags) != 0 ||
        workLoop->sequence != workLoop->begin_count + workLoop->end_count ||
        !metadataAccountingCoversCallbacks || !currentAccountingWithinDrops) {
      return false;
    }
    if ((workLoop->flags & kOSVADiagnosticRecordPresent) != 0) {
      if ((workLoop->flags & kOSVADiagnosticRecordLastCallValid) == 0 ||
          workLoop->last_transition_host_ticks == 0 ||
          workLoop->last_client_id == 0) {
        return false;
      }
    } else if (workLoop->metadata_sequence != 0) {
      return false;
    }
  }
  if (snapshot->reserved_header != 0 ||
      snapshot->last_driver_transition.reserved != 0 ||
      snapshot->last_core_transition.reserved != 0) {
    return false;
  }
  for (size_t index = 0;
       index < sizeof(snapshot->reserved) / sizeof(snapshot->reserved[0]);
       ++index) {
    if (snapshot->reserved[index] != 0) {
      return false;
    }
  }
  return true;
}

static const OSVADiagnosticDriverClientSlotSnapshot *FindDiagnosticDriverSlot(
    const OSVADiagnosticSnapshot *snapshot, UInt32 clientID) {
  for (size_t index = 0; index < kOSVADiagnosticClientSlotCapacity; ++index) {
    const OSVADiagnosticDriverClientSlotSnapshot *slot =
        &snapshot->driver_client_slots[index];
    if ((slot->flags & kOSVADiagnosticDriverSlotRegistered) != 0 &&
        slot->client_id == clientID) {
      return slot;
    }
  }
  return NULL;
}

static bool DiagnosticOperationalStateEqual(
    OSVADiagnosticSnapshot left, OSVADiagnosticSnapshot right) {
  left.snapshot_sequence = 0;
  left.captured_host_ticks = 0;
  right.snapshot_sequence = 0;
  right.captured_host_ticks = 0;
  return memcmp(&left, &right, sizeof(left)) == 0;
}

static bool GetObjectList(AudioServerPlugInDriverRef driver,
                          AudioObjectID objectID,
                          AudioObjectPropertyAddress address,
                          const AudioObjectID *expected, size_t expectedCount) {
  UInt32 fullSize = UINT32_MAX;
  CHECK_STATUS((*driver)->GetPropertyDataSize(driver, objectID, 0, &address, 0,
                                              NULL, &fullSize),
               noErr);
  CHECK(fullSize == expectedCount * sizeof(AudioObjectID));

  AudioObjectID values[8];
  memset(values, 0, sizeof(values));
  UInt32 used = UINT32_MAX;
  CHECK_STATUS((*driver)->GetPropertyData(driver, objectID, 0, &address, 0,
                                          NULL, sizeof(values), &used, values),
               noErr);
  CHECK(used == fullSize);
  CHECK(memcmp(values, expected, used) == 0);

  if (expectedCount > 0) {
    used = UINT32_MAX;
    memset(values, 0, sizeof(values));
    CHECK_STATUS((*driver)->GetPropertyData(driver, objectID, 0, &address, 0,
                                            NULL, sizeof(AudioObjectID), &used,
                                            values),
                 noErr);
    CHECK(used == sizeof(AudioObjectID));
    CHECK(values[0] == expected[0]);
  }
  return true;
}

static bool TestDiagnosticSnapshotPropertyContract(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);

  AudioObjectPropertyAddress address =
      Address(kOSVADiagnosticSnapshotProperty,
              kAudioObjectPropertyScopeGlobal);
  AudioObjectPropertyAddress wrongScope =
      Address(kOSVADiagnosticSnapshotProperty, kAudioObjectPropertyScopeInput);
  AudioObjectPropertyAddress wrongElement = address;
  wrongElement.mElement = 1;
  AudioObjectPropertyAddress infoAddress =
      Address(kAudioObjectPropertyCustomPropertyInfoList,
              kAudioObjectPropertyScopeGlobal);

  const AudioObjectID devices[] = {
      kOSVAObjectIDVisibleInputDevice,
      kOSVAObjectIDHiddenWriterDevice,
  };
  for (size_t index = 0; index < sizeof(devices) / sizeof(devices[0]); ++index) {
    const AudioObjectID device = devices[index];
    CHECK((*driver)->HasProperty(driver, device, 0, &address));
    CHECK(!(*driver)->HasProperty(driver, device, 0, &wrongScope));
    CHECK(!(*driver)->HasProperty(driver, device, 0, &wrongElement));
    CHECK((*driver)->HasProperty(driver, device, 0, &infoAddress));

    Boolean settable = true;
    CHECK_STATUS((*driver)->IsPropertySettable(driver, device, 0, &address,
                                               &settable),
                 noErr);
    CHECK(!settable);

    UInt32 size = 0;
    CHECK_STATUS((*driver)->GetPropertyDataSize(driver, device, 0, &address, 0,
                                                NULL, &size),
                 noErr);
    CHECK(size == sizeof(CFPropertyListRef));

    UInt32 infoSize = 0;
    CHECK_STATUS((*driver)->GetPropertyDataSize(
                     driver, device, 0, &infoAddress, 0, NULL, &infoSize),
                 noErr);
    CHECK(infoSize == sizeof(AudioServerPlugInCustomPropertyInfo));
    AudioServerPlugInCustomPropertyInfo info;
    memset(&info, 0xA5, sizeof(info));
    UInt32 infoUsed = 0;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, device, 0, &infoAddress, 0, NULL,
                     (UInt32)sizeof(info), &infoUsed, &info),
                 noErr);
    CHECK(infoUsed == sizeof(info));
    CHECK(info.mSelector == kOSVADiagnosticSnapshotProperty);
    CHECK(info.mPropertyDataType ==
          kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    CHECK(info.mQualifierDataType ==
          kAudioServerPlugInCustomPropertyDataTypeNone);
    Boolean infoSettable = true;
    CHECK_STATUS((*driver)->IsPropertySettable(
                     driver, device, 0, &infoAddress, &infoSettable),
                 noErr);
    CHECK(!infoSettable);

    unsigned char storage[sizeof(CFPropertyListRef) + 16U];
    memset(storage, 0xA5, sizeof(storage));
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, device, 0, &address, 0, NULL,
                     (UInt32)sizeof(CFPropertyListRef), &used, storage),
                 noErr);
    CHECK(used == sizeof(CFPropertyListRef));
    for (size_t byte = sizeof(CFPropertyListRef); byte < sizeof(storage);
         ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }
    CFPropertyListRef property = NULL;
    memcpy(&property, storage, sizeof(property));
    CHECK(property != NULL);
    CHECK(CFGetTypeID(property) == CFDataGetTypeID());
    CFDataRef data = (CFDataRef)property;
    CHECK(CFDataGetLength(data) == (CFIndex)sizeof(OSVADiagnosticSnapshot));
    OSVADiagnosticSnapshot snapshot;
    CFDataGetBytes(data, CFRangeMake(0, CFDataGetLength(data)),
                   (UInt8 *)&snapshot);
    CFRelease(property);
    property = NULL;
    CHECK(DiagnosticSnapshotIsCoherent(&snapshot));

    memset(storage, 0xA5, sizeof(storage));
    used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, device, 0, &address, 0, NULL,
                     (UInt32)sizeof(CFPropertyListRef) - 1U, &used,
                     storage),
                 kAudioHardwareBadPropertySizeError);
    CHECK(used == 0);
    for (size_t byte = 0; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }

    CHECK_STATUS((*driver)->SetPropertyData(
                     driver, device, 0, &address, 0, NULL,
                     (UInt32)sizeof(property), &property),
                 kAudioHardwareIllegalOperationError);
  }

  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDPlugIn, 0, &address));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputStream, 0,
                                &address));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDHiddenWriterStream, 0,
                                &address));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputVolume, 0,
                                &address));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDHiddenWriterMute, 0,
                                &address));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDPlugIn, 0, &infoAddress));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputStream, 0,
                                &infoAddress));
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDHiddenWriterStream, 0,
                                &infoAddress));

  OSVADiagnosticSnapshot before;
  OSVADiagnosticSnapshot after;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &before),
               noErr);
  for (size_t read = 0; read < 128; ++read) {
    OSVADiagnosticSnapshot repeated;
    CHECK_STATUS(CopyDiagnosticSnapshot(
                     driver, (read & 1U) == 0
                                 ? kOSVAObjectIDVisibleInputDevice
                                 : kOSVAObjectIDHiddenWriterDevice,
                     &repeated),
                 noErr);
    CHECK(DiagnosticSnapshotIsCoherent(&repeated));
    CHECK(repeated.driver_instance_generation ==
          before.driver_instance_generation);
    CHECK(repeated.snapshot_sequence > before.snapshot_sequence);
    CHECK(repeated.captured_host_ticks >= before.captured_host_ticks);
    before = repeated;
  }
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &after),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&after));
  CHECK(DiagnosticOperationalStateEqual(before, after));
  CHECK(gFakeHostState.notificationCount == 0);
  return true;
}

static bool TestFactoryAndCOMInterface(void) {
  CFUUIDRef unsupportedType = CFUUIDCreateFromString(
      kCFAllocatorDefault, CFSTR("00000000-0000-0000-0000-000000000001"));
  CHECK(unsupportedType != NULL);
  CHECK(OpensteamerVirtualMicrophone_Create(kCFAllocatorDefault,
                                            unsupportedType) == NULL);
  CFRelease(unsupportedType);
  CHECK(OpensteamerVirtualMicrophone_Create(kCFAllocatorDefault, NULL) == NULL);

  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  LPVOID queried = NULL;
  CFUUIDBytes bytes = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
  CHECK_STATUS((*driver)->QueryInterface(driver, bytes, &queried), S_OK);
  CHECK(queried == driver);

  CFUUIDRef unknown = CFUUIDCreateFromString(
      kCFAllocatorDefault, CFSTR("00000000-0000-0000-0000-000000000002"));
  CHECK(unknown != NULL);
  bytes = CFUUIDGetUUIDBytes(unknown);
  queried = (LPVOID)(uintptr_t)1;
  CHECK_STATUS((*driver)->QueryInterface(driver, bytes, &queried),
               E_NOINTERFACE);
  CHECK(queried == NULL);
  CFRelease(unknown);
  return true;
}

static bool TestPluginAndUIDTranslation(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);

  const AudioObjectID devices[] = {
      kOSVAObjectIDVisibleInputDevice,
      kOSVAObjectIDHiddenWriterDevice,
  };
  CHECK(GetObjectList(driver, kOSVAObjectIDPlugIn,
                      Address(kAudioObjectPropertyOwnedObjects,
                              kAudioObjectPropertyScopeGlobal),
                      devices, 2));
  CHECK(GetObjectList(
      driver, kOSVAObjectIDPlugIn,
      Address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal),
      devices, 2));
  CHECK(GetCFString(driver, kOSVAObjectIDPlugIn,
                    Address(kAudioObjectPropertyManufacturer,
                            kAudioObjectPropertyScopeGlobal),
                    CFSTR("opensteamer")));
  CHECK(GetCFString(driver, kOSVAObjectIDPlugIn,
                    Address(kAudioPlugInPropertyResourceBundle,
                            kAudioObjectPropertyScopeGlobal),
                    CFSTR("")));

  AudioObjectPropertyAddress translate =
      Address(kAudioPlugInPropertyTranslateUIDToDevice,
              kAudioObjectPropertyScopeGlobal);
  const struct {
    CFStringRef uid;
    AudioObjectID expected;
  } cases[] = {
      {CFSTR(OSVA_VISIBLE_INPUT_DEVICE_UID), kOSVAObjectIDVisibleInputDevice},
      {CFSTR(OSVA_HIDDEN_WRITER_DEVICE_UID), kOSVAObjectIDHiddenWriterDevice},
      {CFSTR("not-a-device"), kAudioObjectUnknown},
  };
  for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
    AudioObjectID value = UINT32_MAX;
    UInt32 used = 0;
    CFStringRef uid = cases[index].uid;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kOSVAObjectIDPlugIn, 0,
                                            &translate, sizeof(uid), &uid,
                                            sizeof(value), &used, &value),
                 noErr);
    CHECK(used == sizeof(value));
    CHECK(value == cases[index].expected);
  }
  UInt32 size = 0;
  CHECK_STATUS((*driver)->GetPropertyDataSize(driver, kOSVAObjectIDPlugIn, 0,
                                              &translate, 0, NULL, &size),
               kAudioHardwareBadPropertySizeError);
  return true;
}

static bool TestRoleScopedTopology(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);

  const AudioObjectID visibleObjects[] = {
      kOSVAObjectIDVisibleInputStream,
      kOSVAObjectIDVisibleInputVolume,
      kOSVAObjectIDVisibleInputMute,
  };
  const AudioObjectID hiddenObjects[] = {
      kOSVAObjectIDHiddenWriterStream,
      kOSVAObjectIDHiddenWriterVolume,
      kOSVAObjectIDHiddenWriterMute,
  };
  const AudioObjectID visibleStream[] = {kOSVAObjectIDVisibleInputStream};
  const AudioObjectID hiddenStream[] = {kOSVAObjectIDHiddenWriterStream};
  const AudioObjectID visibleControls[] = {
      kOSVAObjectIDVisibleInputVolume,
      kOSVAObjectIDVisibleInputMute,
  };
  const AudioObjectID hiddenControls[] = {
      kOSVAObjectIDHiddenWriterVolume,
      kOSVAObjectIDHiddenWriterMute,
  };

  const struct {
    AudioObjectID device;
    AudioObjectPropertyScope roleScope;
    AudioObjectPropertyScope emptyScope;
    const AudioObjectID *objects;
    const AudioObjectID *streams;
    const AudioObjectID *controls;
  } roles[] = {
      {kOSVAObjectIDVisibleInputDevice, kAudioObjectPropertyScopeInput,
       kAudioObjectPropertyScopeOutput, visibleObjects, visibleStream,
       visibleControls},
      {kOSVAObjectIDHiddenWriterDevice, kAudioObjectPropertyScopeOutput,
       kAudioObjectPropertyScopeInput, hiddenObjects, hiddenStream,
       hiddenControls},
  };
  for (size_t index = 0; index < sizeof(roles) / sizeof(roles[0]); ++index) {
    CHECK(GetObjectList(driver, roles[index].device,
                        Address(kAudioObjectPropertyOwnedObjects,
                                kAudioObjectPropertyScopeGlobal),
                        roles[index].objects, 3));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioObjectPropertyOwnedObjects, roles[index].roleScope),
        roles[index].objects, 3));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioObjectPropertyOwnedObjects, roles[index].emptyScope),
        NULL, 0));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioDevicePropertyStreams, roles[index].roleScope),
        roles[index].streams, 1));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioDevicePropertyStreams, roles[index].emptyScope), NULL,
        0));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioObjectPropertyControlList, roles[index].roleScope),
        roles[index].controls, 2));
    CHECK(GetObjectList(
        driver, roles[index].device,
        Address(kAudioObjectPropertyControlList, roles[index].emptyScope), NULL,
        0));
  }
  return true;
}

static bool TestRoleScopedStreamConfiguration(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);

  const UInt32 headerSize = (UInt32)offsetof(AudioBufferList, mBuffers);
  const UInt32 populatedSize = headerSize + (UInt32)sizeof(AudioBuffer);
  const struct {
    AudioObjectID device;
    AudioObjectPropertyScope roleScope;
    AudioObjectPropertyScope emptyScope;
  } roles[] = {
      {kOSVAObjectIDVisibleInputDevice, kAudioObjectPropertyScopeInput,
       kAudioObjectPropertyScopeOutput},
      {kOSVAObjectIDHiddenWriterDevice, kAudioObjectPropertyScopeOutput,
       kAudioObjectPropertyScopeInput},
  };

  for (size_t index = 0; index < sizeof(roles) / sizeof(roles[0]); ++index) {
    const AudioObjectPropertyAddress roleAddress = Address(
        kAudioDevicePropertyStreamConfiguration, roles[index].roleScope);
    const AudioObjectPropertyAddress emptyAddress = Address(
        kAudioDevicePropertyStreamConfiguration, roles[index].emptyScope);
    const AudioObjectPropertyAddress globalAddress = Address(
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertyAddress wrongElementAddress = roleAddress;
    wrongElementAddress.mElement = 1U;
    AudioObjectPropertyAddress wrongScopeAddress = roleAddress;
    wrongScopeAddress.mScope = kAudioObjectPropertyScopeWildcard;
    CHECK((*driver)->HasProperty(driver, roles[index].device, 0,
                                 &roleAddress));
    CHECK((*driver)->HasProperty(driver, roles[index].device, 0,
                                 &emptyAddress));
    CHECK((*driver)->HasProperty(driver, roles[index].device, 0,
                                 &globalAddress));
    CHECK(!(*driver)->HasProperty(driver, roles[index].device, 0,
                                  &wrongElementAddress));
    CHECK(!(*driver)->HasProperty(driver, roles[index].device, 0,
                                  &wrongScopeAddress));
    Boolean settable = true;
    CHECK_STATUS((*driver)->IsPropertySettable(
                     driver, roles[index].device, 0, &roleAddress, &settable),
                 noErr);
    CHECK(!settable);

    UInt32 size = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyDataSize(
                     driver, roles[index].device, 0, &roleAddress, 0, NULL,
                     &size),
                 noErr);
    CHECK(size == populatedSize);
    CHECK_STATUS((*driver)->GetPropertyDataSize(
                     driver, roles[index].device, 0, &emptyAddress, 0, NULL,
                     &size),
                 noErr);
    CHECK(size == headerSize);
    CHECK_STATUS((*driver)->GetPropertyDataSize(
                     driver, roles[index].device, 0, &globalAddress, 0, NULL,
                     &size),
                 noErr);
    CHECK(size == populatedSize);

    uint8_t storage[sizeof(AudioBufferList) + 16U];
    memset(storage, 0xA5, sizeof(storage));
    UInt32 used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, roles[index].device, 0, &roleAddress, 0, NULL,
                     (UInt32)sizeof(storage), &used, storage),
                 noErr);
    CHECK(used == populatedSize);
    UInt32 bufferCount = UINT32_MAX;
    memcpy(&bufferCount, storage, sizeof(bufferCount));
    CHECK(bufferCount == 1U);
    AudioBuffer buffer;
    memcpy(&buffer, storage + headerSize, sizeof(buffer));
    CHECK(buffer.mNumberChannels == 1U);
    CHECK(buffer.mDataByteSize == 0U);
    CHECK(buffer.mData == NULL);
    for (size_t byte = populatedSize; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }

    memset(storage, 0xA5, sizeof(storage));
    used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, roles[index].device, 0, &globalAddress, 0, NULL,
                     (UInt32)sizeof(storage), &used, storage),
                 noErr);
    CHECK(used == populatedSize);
    memcpy(&bufferCount, storage, sizeof(bufferCount));
    CHECK(bufferCount == 1U);
    memcpy(&buffer, storage + headerSize, sizeof(buffer));
    CHECK(buffer.mNumberChannels == 1U);
    CHECK(buffer.mDataByteSize == 0U);
    CHECK(buffer.mData == NULL);
    for (size_t byte = populatedSize; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }

    memset(storage, 0xA5, sizeof(storage));
    used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, roles[index].device, 0, &emptyAddress, 0, NULL,
                     (UInt32)sizeof(storage), &used, storage),
                 noErr);
    CHECK(used == headerSize);
    memcpy(&bufferCount, storage, sizeof(bufferCount));
    CHECK(bufferCount == 0U);
    for (size_t byte = headerSize; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }

    memset(storage, 0xA5, sizeof(storage));
    used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, roles[index].device, 0, &roleAddress, 0, NULL,
                     populatedSize - 1U, &used, storage),
                 kAudioHardwareBadPropertySizeError);
    CHECK(used == 0U);
    for (size_t byte = 0; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }

    memset(storage, 0xA5, sizeof(storage));
    used = UINT32_MAX;
    CHECK_STATUS((*driver)->GetPropertyData(
                     driver, roles[index].device, 0, &emptyAddress, 0, NULL,
                     headerSize - 1U, &used, storage),
                 kAudioHardwareBadPropertySizeError);
    CHECK(used == 0U);
    for (size_t byte = 0; byte < sizeof(storage); ++byte) {
      CHECK(storage[byte] == 0xA5U);
    }
  }
  return true;
}

static bool TestDeviceIdentityVisibilityAndDefaults(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  CHECK(GetCFString(
      driver, kOSVAObjectIDVisibleInputDevice,
      Address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
      CFSTR("opensteamer Virtual Microphone")));
  CHECK(GetCFString(
      driver, kOSVAObjectIDHiddenWriterDevice,
      Address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
      CFSTR("opensteamer Virtual Microphone Writer")));
  CHECK(GetCFString(
      driver, kOSVAObjectIDVisibleInputDevice,
      Address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal),
      CFSTR(OSVA_VISIBLE_INPUT_DEVICE_UID)));
  CHECK(GetCFString(
      driver, kOSVAObjectIDHiddenWriterDevice,
      Address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal),
      CFSTR(OSVA_HIDDEN_WRITER_DEVICE_UID)));
  CHECK(GetCFString(
      driver, kOSVAObjectIDVisibleInputDevice,
      Address(kAudioDevicePropertyModelUID, kAudioObjectPropertyScopeGlobal),
      CFSTR(OSVA_DEVICE_MODEL_UID)));

  CHECK(GetUInt32(
      driver, kOSVAObjectIDVisibleInputDevice,
      Address(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal),
      0));
  CHECK(GetUInt32(
      driver, kOSVAObjectIDHiddenWriterDevice,
      Address(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal),
      1));
  CHECK(GetUInt32(driver, kOSVAObjectIDVisibleInputDevice,
                  Address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                          kAudioObjectPropertyScopeInput),
                  1));
  CHECK(GetUInt32(driver, kOSVAObjectIDVisibleInputDevice,
                  Address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                          kAudioObjectPropertyScopeOutput),
                  0));
  CHECK(GetUInt32(driver, kOSVAObjectIDHiddenWriterDevice,
                  Address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                          kAudioObjectPropertyScopeInput),
                  0));
  CHECK(GetUInt32(driver, kOSVAObjectIDHiddenWriterDevice,
                  Address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                          kAudioObjectPropertyScopeOutput),
                  0));
  CHECK(GetUInt32(driver, kOSVAObjectIDVisibleInputDevice,
                  Address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                          kAudioObjectPropertyScopeInput),
                  0));

  AudioObjectPropertyAddress stereo =
      Address(kAudioDevicePropertyPreferredChannelsForStereo,
              kAudioObjectPropertyScopeInput);
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputDevice, 0,
                                &stereo));
  return true;
}

static bool CheckExactMonoASBD(const AudioStreamBasicDescription *format) {
  CHECK(format->mSampleRate == 48000.0);
  CHECK(format->mFormatID == kAudioFormatLinearPCM);
  CHECK(format->mFormatFlags ==
        (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
         kAudioFormatFlagIsPacked));
  CHECK(format->mBytesPerPacket == 4);
  CHECK(format->mFramesPerPacket == 1);
  CHECK(format->mBytesPerFrame == 4);
  CHECK(format->mChannelsPerFrame == 1);
  CHECK(format->mBitsPerChannel == 32);
  return true;
}

static bool CheckMonoStream(AudioServerPlugInDriverRef driver,
                            AudioObjectID streamObjectID, bool isInput) {
  const AudioObjectPropertySelector formatSelectors[] = {
      kAudioStreamPropertyVirtualFormat,
      kAudioStreamPropertyPhysicalFormat,
  };
  for (size_t index = 0;
       index < sizeof(formatSelectors) / sizeof(formatSelectors[0]); ++index) {
    AudioObjectPropertyAddress formatAddress =
        Address(formatSelectors[index], kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, streamObjectID, 0,
                                            &formatAddress, 0, NULL,
                                            sizeof(format), &used, &format),
                 noErr);
    CHECK(used == sizeof(format));
    CHECK(CheckExactMonoASBD(&format));
  }

  const AudioObjectPropertySelector availableSelectors[] = {
      kAudioStreamPropertyAvailableVirtualFormats,
      kAudioStreamPropertyAvailablePhysicalFormats,
  };
  for (size_t index = 0;
       index < sizeof(availableSelectors) / sizeof(availableSelectors[0]);
       ++index) {
    AudioObjectPropertyAddress availableAddress =
        Address(availableSelectors[index], kAudioObjectPropertyScopeGlobal);
    AudioStreamRangedDescription ranged;
    memset(&ranged, 0, sizeof(ranged));
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, streamObjectID, 0,
                                            &availableAddress, 0, NULL,
                                            sizeof(ranged), &used, &ranged),
                 noErr);
    CHECK(used == sizeof(ranged));
    CHECK(CheckExactMonoASBD(&ranged.mFormat));
    CHECK(ranged.mSampleRateRange.mMinimum == 48000.0);
    CHECK(ranged.mSampleRateRange.mMaximum == 48000.0);
  }
  CHECK(GetUInt32(
      driver, streamObjectID,
      Address(kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal),
      isInput ? 1U : 0U));
  CHECK(GetUInt32(driver, streamObjectID,
                  Address(kAudioStreamPropertyTerminalType,
                          kAudioObjectPropertyScopeGlobal),
                  isInput ? kAudioStreamTerminalTypeMicrophone
                          : kAudioStreamTerminalTypeSpeaker));
  return true;
}

static bool TestMonoFormatsAndClockContract(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  CHECK(CheckMonoStream(driver, kOSVAObjectIDVisibleInputStream, true));
  CHECK(CheckMonoStream(driver, kOSVAObjectIDHiddenWriterStream, false));

  for (AudioObjectID device = kOSVAObjectIDVisibleInputDevice;
       device <= kOSVAObjectIDHiddenWriterDevice;
       device +=
       kOSVAObjectIDHiddenWriterDevice - kOSVAObjectIDVisibleInputDevice) {
    CHECK(GetUInt32(driver, device,
                    Address(kAudioDevicePropertyClockDomain,
                            kAudioObjectPropertyScopeGlobal),
                    kOSVAClockDomain));
    CHECK(GetUInt32(driver, device,
                    Address(kAudioDevicePropertyZeroTimeStampPeriod,
                            kAudioObjectPropertyScopeGlobal),
                    kOSVAZeroTimeStampPeriodFrames));
    CHECK(GetUInt32(driver, device,
                    Address(kAudioDevicePropertyClockAlgorithm,
                            kAudioObjectPropertyScopeGlobal),
                    kAudioDeviceClockAlgorithmRaw));
    CHECK(GetUInt32(driver, device,
                    Address(kAudioDevicePropertyClockIsStable,
                            kAudioObjectPropertyScopeGlobal),
                    1));
  }

  AudioObjectPropertyAddress layoutAddress =
      Address(kAudioDevicePropertyPreferredChannelLayout,
              kAudioObjectPropertyScopeInput);
  AudioChannelLayout layout;
  memset(&layout, 0, sizeof(layout));
  UInt32 used = 0;
  CHECK_STATUS((*driver)->GetPropertyData(
                   driver, kOSVAObjectIDVisibleInputDevice, 0, &layoutAddress,
                   0, NULL, sizeof(layout), &used, &layout),
               noErr);
  CHECK(used == offsetof(AudioChannelLayout, mChannelDescriptions));
  CHECK(layout.mChannelLayoutTag == kAudioChannelLayoutTag_Mono);
  CHECK(layout.mChannelBitmap == 0);
  CHECK(layout.mNumberChannelDescriptions == 0);
  return true;
}

static bool TestReadOnlyUnityControls(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  const struct {
    AudioObjectID volume;
    AudioObjectID mute;
    AudioObjectPropertyScope roleScope;
  } roles[] = {
      {kOSVAObjectIDVisibleInputVolume, kOSVAObjectIDVisibleInputMute,
       kAudioObjectPropertyScopeInput},
      {kOSVAObjectIDHiddenWriterVolume, kOSVAObjectIDHiddenWriterMute,
       kAudioObjectPropertyScopeOutput},
  };
  for (size_t index = 0; index < sizeof(roles) / sizeof(roles[0]); ++index) {
    CHECK(GetFloat32(driver, roles[index].volume,
                     Address(kAudioLevelControlPropertyScalarValue,
                             kAudioObjectPropertyScopeGlobal),
                     1.0F));
    CHECK(GetFloat32(driver, roles[index].volume,
                     Address(kAudioLevelControlPropertyDecibelValue,
                             kAudioObjectPropertyScopeGlobal),
                     0.0F));
    CHECK(GetFloat32(driver, roles[index].volume,
                     Address(kAudioLevelControlPropertyConvertScalarToDecibels,
                             kAudioObjectPropertyScopeGlobal),
                     0.0F));
    CHECK(GetFloat32(driver, roles[index].volume,
                     Address(kAudioLevelControlPropertyConvertDecibelsToScalar,
                             kAudioObjectPropertyScopeGlobal),
                     1.0F));
    CHECK(GetUInt32(
        driver, roles[index].volume,
        Address(kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal),
        roles[index].roleScope));
    CHECK(GetUInt32(driver, roles[index].mute,
                    Address(kAudioBooleanControlPropertyValue,
                            kAudioObjectPropertyScopeGlobal),
                    0));

    AudioObjectPropertyAddress scalar = Address(
        kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    Boolean settable = true;
    CHECK_STATUS((*driver)->IsPropertySettable(driver, roles[index].volume, 0,
                                               &scalar, &settable),
                 noErr);
    CHECK(!settable);
    Float32 attemptedValue = 0.25F;
    CHECK_STATUS((*driver)->SetPropertyData(
                     driver, roles[index].volume, 0, &scalar, 0, NULL,
                     sizeof(attemptedValue), &attemptedValue),
                 kAudioHardwareIllegalOperationError);
  }
  return true;
}

static bool TestPropertyErrorContract(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioObjectPropertyAddress unknown =
      Address('nope', kAudioObjectPropertyScopeGlobal);
  Boolean settable = true;
  CHECK_STATUS((*driver)->IsPropertySettable(driver,
                                             kOSVAObjectIDVisibleInputDevice, 0,
                                             &unknown, &settable),
               kAudioHardwareUnknownPropertyError);
  CHECK_STATUS(
      (*driver)->IsPropertySettable(driver, 999, 0, &unknown, &settable),
      kAudioHardwareBadObjectError);
  const AudioObjectPropertyAddress *nullAddress =
      (const AudioObjectPropertyAddress *)(uintptr_t)
          gFakeHostState.lastObjectID;
  CHECK_STATUS((*driver)->IsPropertySettable(driver,
                                             kOSVAObjectIDVisibleInputDevice, 0,
                                             nullAddress, &settable),
               kAudioHardwareIllegalOperationError);

  AudioObjectPropertyAddress alive = Address(kAudioDevicePropertyDeviceIsAlive,
                                             kAudioObjectPropertyScopeGlobal);
  UInt32 value = 0;
  UInt32 used = 0;
  CHECK_STATUS((*driver)->GetPropertyData(
                   driver, kOSVAObjectIDVisibleInputDevice, 0, &alive, 0, NULL,
                   sizeof(UInt16), &used, &value),
               kAudioHardwareBadPropertySizeError);
  alive.mElement = 1;
  CHECK(!(*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputDevice, 0,
                                &alive));
  return true;
}

static bool TestObjectClassAndOwnershipMatrix(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  const struct {
    AudioObjectID objectID;
    AudioClassID baseClass;
    AudioClassID objectClass;
    AudioObjectID owner;
  } objects[] = {
      {kOSVAObjectIDPlugIn, kAudioObjectClassID, kAudioPlugInClassID,
       kAudioObjectUnknown},
      {kOSVAObjectIDVisibleInputDevice, kAudioObjectClassID,
       kAudioDeviceClassID, kOSVAObjectIDPlugIn},
      {kOSVAObjectIDVisibleInputStream, kAudioObjectClassID,
       kAudioStreamClassID, kOSVAObjectIDVisibleInputDevice},
      {kOSVAObjectIDVisibleInputVolume, kAudioLevelControlClassID,
       kAudioVolumeControlClassID, kOSVAObjectIDVisibleInputDevice},
      {kOSVAObjectIDVisibleInputMute, kAudioBooleanControlClassID,
       kAudioMuteControlClassID, kOSVAObjectIDVisibleInputDevice},
      {kOSVAObjectIDHiddenWriterDevice, kAudioObjectClassID,
       kAudioDeviceClassID, kOSVAObjectIDPlugIn},
      {kOSVAObjectIDHiddenWriterStream, kAudioObjectClassID,
       kAudioStreamClassID, kOSVAObjectIDHiddenWriterDevice},
      {kOSVAObjectIDHiddenWriterVolume, kAudioLevelControlClassID,
       kAudioVolumeControlClassID, kOSVAObjectIDHiddenWriterDevice},
      {kOSVAObjectIDHiddenWriterMute, kAudioBooleanControlClassID,
       kAudioMuteControlClassID, kOSVAObjectIDHiddenWriterDevice},
  };
  for (size_t index = 0; index < sizeof(objects) / sizeof(objects[0]);
       ++index) {
    CHECK(GetUInt32(
        driver, objects[index].objectID,
        Address(kAudioObjectPropertyBaseClass, kAudioObjectPropertyScopeGlobal),
        objects[index].baseClass));
    CHECK(GetUInt32(
        driver, objects[index].objectID,
        Address(kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal),
        objects[index].objectClass));
    CHECK(GetUInt32(
        driver, objects[index].objectID,
        Address(kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal),
        objects[index].owner));
  }
  return true;
}

static bool TestExactIOOperationAdvertisement(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  const struct {
    AudioObjectID device;
    UInt32 operation;
    Boolean expected;
  } cases[] = {
      {kOSVAObjectIDVisibleInputDevice, kAudioServerPlugInIOOperationReadInput,
       true},
      {kOSVAObjectIDVisibleInputDevice, kAudioServerPlugInIOOperationWriteMix,
       false},
      {kOSVAObjectIDVisibleInputDevice, kAudioServerPlugInIOOperationThread,
       false},
      {kOSVAObjectIDHiddenWriterDevice, kAudioServerPlugInIOOperationWriteMix,
       true},
      {kOSVAObjectIDHiddenWriterDevice, kAudioServerPlugInIOOperationReadInput,
       false},
      {kOSVAObjectIDHiddenWriterDevice, kAudioServerPlugInIOOperationCycle,
       false},
  };
  for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
    Boolean willDo = true;
    Boolean inPlace = true;
    CHECK_STATUS((*driver)->WillDoIOOperation(driver, cases[index].device, 55,
                                              cases[index].operation, &willDo,
                                              &inPlace),
                 noErr);
    CHECK(willDo == cases[index].expected);
    CHECK(inPlace == cases[index].expected);
  }

  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));
  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 55,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS(
      (*driver)->EndIOOperation(driver, kOSVAObjectIDVisibleInputDevice, 55,
                                kAudioServerPlugInIOOperationThread, 0, &cycle),
      noErr);
  const AudioServerPlugInIOCycleInfo *nullCycle =
      (const AudioServerPlugInIOCycleInfo *)(uintptr_t)
          gFakeHostState.lastObjectID;
  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 55,
                   kAudioServerPlugInIOOperationReadInput, 64, nullCycle),
               kAudioHardwareIllegalOperationError);
  return true;
}

static bool TestIOWorkLoopDiagnosticBookkeeping(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));

  OSVADiagnosticSnapshot idle;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &idle),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&idle));
  for (size_t endpoint = 0; endpoint < 2; ++endpoint) {
    CHECK(idle.io_work_loop[endpoint].current_count == 0);
    CHECK(idle.io_work_loop[endpoint].begin_count == 0);
    CHECK(idle.io_work_loop[endpoint].end_count == 0);
    CHECK(idle.io_work_loop[endpoint].underflow_count == 0);
  }

  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 71,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 72,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  OSVADiagnosticSnapshot nested;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &nested),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&nested));
  CHECK(nested.io_work_loop[0].current_count == 2);
  CHECK(nested.io_work_loop[0].begin_count == 2);
  CHECK(nested.io_work_loop[0].end_count == 0);
  CHECK(nested.io_work_loop[0].underflow_count == 0);

  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 72,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 71,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 73,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice, 81,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice, 81,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);

  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 91,
                   kAudioServerPlugInIOOperationCycle, 0, &cycle),
               noErr);
  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 91,
                   kAudioServerPlugInIOOperationCycle, 0, &cycle),
               noErr);

  OSVADiagnosticSnapshot balanced;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &balanced),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&balanced));
  const OSVADiagnosticIOWorkLoopSnapshot *visible =
      &balanced.io_work_loop[0];
  const OSVADiagnosticIOWorkLoopSnapshot *writer =
      &balanced.io_work_loop[1];
  CHECK(visible->current_count == 0);
  CHECK(visible->begin_count == 2);
  CHECK(visible->end_count == 3);
  CHECK(visible->underflow_count == 1);
  CHECK(visible->last_transition_host_ticks != 0);
  CHECK(visible->last_client_id == 73);
  CHECK((visible->flags & kOSVADiagnosticRecordPresent) != 0);
  CHECK((visible->flags & kOSVADiagnosticRecordLastCallValid) != 0);
  CHECK(writer->current_count == 0);
  CHECK(writer->begin_count == 1);
  CHECK(writer->end_count == 1);
  CHECK(writer->underflow_count == 0);
  CHECK(writer->last_client_id == 81);

  OSVADiagnosticSnapshot repeated;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &repeated),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&repeated));
  CHECK(memcmp(balanced.io_work_loop, repeated.io_work_loop,
               sizeof(balanced.io_work_loop)) == 0);
  return true;
}

static bool TestIOWorkLoopCurrentCountDropAccounting(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));

  CHECK_STATUS(OSVADriverForceNextIOWorkLoopCurrentCountDropForTesting(),
               noErr);
  CHECK_STATUS(OSVADriverForceNextIOWorkLoopCurrentCountDropForTesting(),
               kAudioHardwareIllegalOperationError);
  CHECK_STATUS((*driver)->BeginIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 82,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);

  OSVADiagnosticSnapshot droppedBegin;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &droppedBegin),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&droppedBegin));
  const OSVADiagnosticIOWorkLoopSnapshot *dropped =
      &droppedBegin.io_work_loop[0];
  CHECK(dropped->sequence == 1);
  CHECK(dropped->current_count == 0);
  CHECK(dropped->begin_count == 1);
  CHECK(dropped->end_count == 0);
  CHECK(dropped->underflow_count == 0);
  CHECK(dropped->metadata_sequence == 2);
  CHECK(dropped->metadata_dropped_update_count == 1);
  CHECK(dropped->last_client_id == 82);

  CHECK_STATUS((*driver)->EndIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice, 82,
                   kAudioServerPlugInIOOperationThread, 0, &cycle),
               noErr);
  OSVADiagnosticSnapshot paired;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &paired),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&paired));
  const OSVADiagnosticIOWorkLoopSnapshot *afterEnd =
      &paired.io_work_loop[0];
  CHECK(afterEnd->sequence == 2);
  CHECK(afterEnd->current_count == 0);
  CHECK(afterEnd->begin_count == 1);
  CHECK(afterEnd->end_count == 1);
  CHECK(afterEnd->underflow_count == 1);
  CHECK(afterEnd->metadata_sequence == 4);
  CHECK(afterEnd->metadata_dropped_update_count == 1);
  CHECK(afterEnd->last_client_id == 82);
  return true;
}

static AudioServerPlugInClientInfo ClientInfo(UInt32 clientID) {
  AudioServerPlugInClientInfo info = {
      .mClientID = clientID,
      .mProcessID = 1234,
      .mIsNativeEndian = true,
      .mBundleID = CFSTR("com.elamin.opensteamer.driver-tests"),
  };
  return info;
}

static bool RunSharedTimelineStartOrder(AudioObjectID firstDevice,
                                        UInt32 firstClientID,
                                        AudioObjectID secondDevice,
                                        UInt32 secondClientID) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo first = ClientInfo(firstClientID);
  AudioServerPlugInClientInfo second = ClientInfo(secondClientID);
  CHECK_STATUS((*driver)->AddDeviceClient(driver, firstDevice, &first), noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(driver, secondDevice, &second),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, firstDevice, firstClientID), noErr);
  CHECK_STATUS((*driver)->StartIO(driver, secondDevice, secondClientID), noErr);

  Float64 firstSample = -1.0;
  Float64 secondSample = -1.0;
  UInt64 firstHost = 0;
  UInt64 secondHost = 0;
  UInt64 firstSeed = 0;
  UInt64 secondSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(driver, firstDevice, firstClientID,
                                           &firstSample, &firstHost,
                                           &firstSeed),
               noErr);
  CHECK_STATUS((*driver)->GetZeroTimeStamp(driver, secondDevice, secondClientID,
                                           &secondSample, &secondHost,
                                           &secondSeed),
               noErr);
  CHECK(firstSeed != 0);
  CHECK(firstSeed == secondSeed);
  CHECK(firstSample >= 0.0);
  CHECK(secondSample >= firstSample);
  CHECK(fmod(firstSample, (Float64)kOSVAZeroTimeStampPeriodFrames) == 0.0);
  CHECK(fmod(secondSample, (Float64)kOSVAZeroTimeStampPeriodFrames) == 0.0);
  CHECK(firstHost != 0);
  CHECK(secondHost >= firstHost);

  CHECK_STATUS((*driver)->StopIO(driver, firstDevice, firstClientID), noErr);
  CHECK_STATUS((*driver)->StopIO(driver, secondDevice, secondClientID), noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(driver, firstDevice, &first),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(driver, secondDevice, &second),
               noErr);
  return true;
}

static bool TestSharedTimelineBothStartOrdersAndRestartSeed(void) {
  CHECK(RunSharedTimelineStartOrder(kOSVAObjectIDVisibleInputDevice, 101,
                                    kOSVAObjectIDHiddenWriterDevice, 201));
  CHECK(RunSharedTimelineStartOrder(kOSVAObjectIDHiddenWriterDevice, 202,
                                    kOSVAObjectIDVisibleInputDevice, 102));

  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(103);
  AudioServerPlugInClientInfo writer = ClientInfo(203);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  Float64 sample = 0;
  UInt64 host = 0;
  UInt64 firstSeed = 0;
  CHECK_STATUS(
      (*driver)->GetZeroTimeStamp(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID, &sample, &host, &firstSeed),
      noErr);
  OSVADiagnosticSnapshot firstEpoch;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &firstEpoch),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&firstEpoch));
  CHECK(firstEpoch.current_seed_generation == firstSeed);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  UInt64 secondSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDHiddenWriterDevice, writer.mClientID,
                   &sample, &host, &secondSeed),
               noErr);
  CHECK(secondSeed != 0);
  CHECK(secondSeed != firstSeed);
  OSVADiagnosticSnapshot secondEpoch;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &secondEpoch),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&secondEpoch));
  CHECK(secondEpoch.current_seed_generation == secondSeed);
  CHECK(secondEpoch.driver_instance_generation ==
        firstEpoch.driver_instance_generation);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  return true;
}

static bool TestSeedGenerationDriverInstanceDisambiguation(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(104);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  OSVADiagnosticSnapshot firstInstance;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &firstInstance),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&firstInstance));
  CHECK(firstInstance.current_seed_generation == firstInstance.timeline_seed);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);

  driver = FreshDriver();
  CHECK(driver != NULL);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  OSVADiagnosticSnapshot secondInstance;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &secondInstance),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&secondInstance));
  CHECK(secondInstance.current_seed_generation ==
        secondInstance.timeline_seed);
  CHECK(secondInstance.current_seed_generation ==
        firstInstance.current_seed_generation);
  CHECK(secondInstance.driver_instance_generation >
        firstInstance.driver_instance_generation);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  return true;
}

static bool TestClientLifecycleAndRunningNotifications(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo first = ClientInfo(301);
  AudioServerPlugInClientInfo second = ClientInfo(302);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &first),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &first),
               kAudioHardwareIllegalOperationError);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice, 999),
               kAudioHardwareIllegalOperationError);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &second),
               noErr);

  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  first.mClientID),
               noErr);
  CHECK(gFakeHostState.notificationCount == 1);
  CHECK(gFakeHostState.lastObjectID == kOSVAObjectIDVisibleInputDevice);
  CHECK(gFakeHostState.lastAddress.mSelector ==
        kAudioDevicePropertyDeviceIsRunning);
  CHECK(GetUInt32(driver, kOSVAObjectIDVisibleInputDevice,
                  Address(kAudioDevicePropertyDeviceIsRunning,
                          kAudioObjectPropertyScopeGlobal),
                  1));
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  first.mClientID),
               kAudioHardwareIllegalOperationError);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  second.mClientID),
               noErr);
  CHECK(gFakeHostState.notificationCount == 1);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &first),
               kAudioHardwareIllegalOperationError);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 first.mClientID),
               noErr);
  CHECK(gFakeHostState.notificationCount == 1);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 second.mClientID),
               noErr);
  CHECK(gFakeHostState.notificationCount == 2);
  CHECK(GetUInt32(driver, kOSVAObjectIDVisibleInputDevice,
                  Address(kAudioDevicePropertyDeviceIsRunning,
                          kAudioObjectPropertyScopeGlobal),
                  0));
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 second.mClientID),
               kAudioHardwareIllegalOperationError);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &first),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &second),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &second),
               kAudioHardwareIllegalOperationError);
  return true;
}

static AudioServerPlugInIOCycleInfo CycleAtInputFrame(Float64 frame) {
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));
  cycle.mInputTime.mSampleTime = frame;
  cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
  return cycle;
}

static AudioServerPlugInIOCycleInfo CycleAtOutputFrame(Float64 frame) {
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));
  cycle.mOutputTime.mSampleTime = frame;
  cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
  return cycle;
}

static bool AllSamplesEqual(const Float32 *samples, size_t count,
                            Float32 expected) {
  for (size_t index = 0; index < count; ++index) {
    if (samples[index] != expected) {
      return false;
    }
  }
  return true;
}

static bool TestDiagnosticSnapshotLifecycleAndAudioRecords(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(801);
  AudioServerPlugInClientInfo writer = ClientInfo(802);

  OSVADiagnosticSnapshot snapshot;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 0);
  CHECK(snapshot.driver_registered_count == 0);
  CHECK(snapshot.driver_started_count == 0);
  CHECK(snapshot.timeline_seed == 0);
  CHECK(snapshot.anchor_host_ticks == 0);
  CHECK(snapshot.seed_create_count == 0);
  CHECK(snapshot.seed_clear_count == 0);
  const UInt64 idleLifecycleSequence = snapshot.driver_lifecycle_sequence;

  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 0);
  CHECK(snapshot.driver_registered_count == 2);
  CHECK(snapshot.visible_driver_registered_count == 1);
  CHECK(snapshot.hidden_driver_registered_count == 1);
  CHECK(snapshot.driver_started_count == 0);
  CHECK(snapshot.driver_client_add_attempt_count == 2);
  CHECK(snapshot.driver_client_add_count == 2);
  CHECK(snapshot.last_driver_transition.type ==
        kOSVADiagnosticTransitionDriverClientAdded);
  CHECK(snapshot.last_driver_transition.client_id == writer.mClientID);
  CHECK(snapshot.driver_lifecycle_sequence > idleLifecycleSequence);
  const UInt64 registeredLifecycleSequence =
      snapshot.driver_lifecycle_sequence;
  const OSVADiagnosticDriverClientSlotSnapshot *readerSlot =
      FindDiagnosticDriverSlot(&snapshot, reader.mClientID);
  const OSVADiagnosticDriverClientSlotSnapshot *writerSlot =
      FindDiagnosticDriverSlot(&snapshot, writer.mClientID);
  CHECK(readerSlot != NULL);
  CHECK(writerSlot != NULL);
  CHECK(readerSlot->device_object_id == kOSVAObjectIDVisibleInputDevice);
  CHECK(readerSlot->process_id == reader.mProcessID);
  CHECK(readerSlot->endpoint_role == kOSVADiagnosticEndpointVisibleInput);
  CHECK(writerSlot->device_object_id == kOSVAObjectIDHiddenWriterDevice);
  CHECK(writerSlot->process_id == writer.mProcessID);
  CHECK(writerSlot->endpoint_role == kOSVADiagnosticEndpointHiddenWriter);
  CHECK(snapshot.last_driver_transition.endpoint_role ==
        kOSVADiagnosticEndpointHiddenWriter);
  CHECK(snapshot.last_driver_transition.slot_index ==
        (UInt32)(writerSlot - snapshot.driver_client_slots));
  CHECK(snapshot.last_driver_transition.process_id == writer.mProcessID);
  CHECK(snapshot.last_driver_transition.driver_client_generation ==
        writerSlot->generation);
  CHECK(snapshot.last_driver_transition.core_session_id == 0);
  CHECK(snapshot.last_driver_transition.pre_global_active_count == 0);
  CHECK(snapshot.last_driver_transition.post_global_active_count == 0);

  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 1);
  CHECK(snapshot.visible_input_active_count == 1);
  CHECK(snapshot.hidden_writer_active_count == 0);
  CHECK(snapshot.driver_started_count == 1);
  CHECK(snapshot.visible_driver_started_count == 1);
  CHECK(snapshot.timeline_seed != 0);
  CHECK(snapshot.current_seed_generation != 0);
  CHECK(snapshot.anchor_host_ticks != 0);
  CHECK(snapshot.seed_create_count == 1);
  CHECK(snapshot.seed_clear_count == 0);
  CHECK(snapshot.global_start_attempt_count == 1);
  CHECK(snapshot.global_start_transition_count == 1);
  CHECK(snapshot.driver_lifecycle_sequence > registeredLifecycleSequence);
  const UInt64 readerStartedLifecycleSequence =
      snapshot.driver_lifecycle_sequence;
  const UInt64 activeSeed = snapshot.timeline_seed;
  const UInt64 activeSeedGeneration = snapshot.current_seed_generation;
  CHECK(activeSeedGeneration == activeSeed);
  const UInt64 activeAnchor = snapshot.anchor_host_ticks;
  readerSlot = FindDiagnosticDriverSlot(&snapshot, reader.mClientID);
  CHECK(readerSlot != NULL);
  CHECK(snapshot.last_driver_transition.type ==
        kOSVADiagnosticTransitionIOStarted);
  CHECK(snapshot.last_driver_transition.client_id == reader.mClientID);
  CHECK(snapshot.last_driver_transition.process_id == reader.mProcessID);
  CHECK(snapshot.last_driver_transition.driver_client_generation ==
        readerSlot->generation);
  CHECK(snapshot.last_driver_transition.core_session_id ==
        readerSlot->lease_session_id);
  CHECK(snapshot.last_driver_transition.slot_index ==
        (UInt32)(readerSlot - snapshot.driver_client_slots));
  CHECK(snapshot.last_core_transition.type ==
        kOSVADiagnosticTransitionSeedCreated);
  CHECK(snapshot.last_core_transition.client_id ==
        (((UInt64)kOSVAObjectIDVisibleInputDevice << 32U) |
         (UInt64)reader.mClientID));
  CHECK(snapshot.last_core_transition.process_id == reader.mProcessID);
  CHECK(snapshot.last_core_transition.driver_client_generation ==
        readerSlot->generation);
  CHECK(snapshot.last_core_transition.core_session_id ==
        readerSlot->lease_session_id);
  CHECK(snapshot.last_core_transition.slot_index ==
        readerSlot->core_client_slot);

  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 2);
  CHECK(snapshot.visible_input_active_count == 1);
  CHECK(snapshot.hidden_writer_active_count == 1);
  CHECK(snapshot.driver_started_count == 2);
  CHECK(snapshot.timeline_seed == activeSeed);
  CHECK(snapshot.current_seed_generation == activeSeedGeneration);
  CHECK(snapshot.anchor_host_ticks == activeAnchor);
  CHECK(snapshot.seed_create_count == 1);
  CHECK(snapshot.global_start_attempt_count == 2);
  CHECK(snapshot.global_start_transition_count == 2);
  CHECK(snapshot.driver_lifecycle_sequence > readerStartedLifecycleSequence);
  const UInt64 bothStartedLifecycleSequence =
      snapshot.driver_lifecycle_sequence;
  writerSlot = FindDiagnosticDriverSlot(&snapshot, writer.mClientID);
  CHECK(writerSlot != NULL);
  CHECK(snapshot.last_driver_transition.type ==
        kOSVADiagnosticTransitionIOStarted);
  CHECK(snapshot.last_driver_transition.client_id == writer.mClientID);
  CHECK(snapshot.last_driver_transition.process_id == writer.mProcessID);
  CHECK(snapshot.last_driver_transition.driver_client_generation ==
        writerSlot->generation);
  CHECK(snapshot.last_driver_transition.core_session_id ==
        writerSlot->lease_session_id);
  CHECK(snapshot.last_core_transition.type ==
        kOSVADiagnosticTransitionIOStarted);
  CHECK(snapshot.last_core_transition.client_id ==
        (((UInt64)kOSVAObjectIDHiddenWriterDevice << 32U) |
         (UInt64)writer.mClientID));
  CHECK(snapshot.last_core_transition.process_id == writer.mProcessID);
  CHECK(snapshot.last_core_transition.driver_client_generation ==
        writerSlot->generation);
  CHECK(snapshot.last_core_transition.core_session_id ==
        writerSlot->lease_session_id);

  Float64 visibleSample = -1.0;
  Float64 writerSample = -1.0;
  UInt64 visibleHost = 0;
  UInt64 writerHost = 0;
  UInt64 visibleSeed = 0;
  UInt64 writerSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &visibleSample, &visibleHost, &visibleSeed),
               noErr);
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDHiddenWriterDevice, writer.mClientID,
                   &writerSample, &writerHost, &writerSeed),
               noErr);
  CHECK(visibleSeed == activeSeed);
  CHECK(writerSeed == activeSeed);

  Float32 source[] = {0.125F, -0.25F, 0.5F, -0.75F};
  Float32 destination[sizeof(source) / sizeof(source[0])] = {0};
  const UInt32 frameCount =
      (UInt32)(sizeof(source) / sizeof(source[0]));
  const UInt64 firstFrame = 4096;
  AudioServerPlugInIOCycleInfo outputCycle =
      CycleAtOutputFrame((Float64)firstFrame);
  AudioServerPlugInIOCycleInfo inputCycle =
      CycleAtInputFrame((Float64)firstFrame);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &outputCycle, source, NULL),
               noErr);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);

  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.driver_lifecycle_sequence == bothStartedLifecycleSequence);
  for (size_t endpoint = 0; endpoint < 2; ++endpoint) {
    const OSVADiagnosticZeroTimestampSnapshot *zero =
        &snapshot.zero_timestamp[endpoint];
    CHECK(zero->call_count == 1);
    CHECK(zero->successful_return_count == 1);
    CHECK(zero->fallback_return_count == 0);
    CHECK(zero->failed_return_count == 0);
    CHECK((zero->flags & kOSVADiagnosticRecordPresent) != 0);
    CHECK((zero->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0);
    CHECK((zero->flags & kOSVADiagnosticRecordLastCallValid) != 0);
    CHECK((zero->flags & kOSVADiagnosticRecordEpochMappingValid) != 0);
    CHECK(zero->last_seed == activeSeed);
    CHECK(zero->last_seed_generation == activeSeedGeneration);
    CHECK(zero->last_core_lifecycle_sequence ==
          snapshot.core_lifecycle_sequence);
    CHECK(zero->last_call_core_lifecycle_sequence ==
          snapshot.core_lifecycle_sequence);
  }
  CHECK(snapshot.zero_timestamp[0].last_client_id == reader.mClientID);
  CHECK(snapshot.zero_timestamp[1].last_client_id == writer.mClientID);
  CHECK(snapshot.zero_timestamp[0].last_sample_frame ==
        (UInt64)visibleSample);
  CHECK(snapshot.zero_timestamp[1].last_sample_frame ==
        (UInt64)writerSample);
  CHECK(snapshot.zero_timestamp[0].last_host_ticks == visibleHost);
  CHECK(snapshot.zero_timestamp[1].last_host_ticks == writerHost);

  const OSVADiagnosticIOSnapshot *visibleIO = &snapshot.io[0];
  const OSVADiagnosticIOSnapshot *writerIO = &snapshot.io[1];
  CHECK(visibleIO->operation_call_count == 1);
  CHECK(visibleIO->valid_cycle_count == 1);
  CHECK(visibleIO->invalid_cycle_count == 0);
  CHECK(visibleIO->core_ok_count == 1);
  CHECK(visibleIO->requested_frame_count == frameCount);
  CHECK(visibleIO->transferred_frame_count == frameCount);
  CHECK(visibleIO->gap_frame_count == 0);
  CHECK(visibleIO->last_cycle_sample_frame == firstFrame);
  CHECK(visibleIO->last_consumed_frame_seed == activeSeed);
  CHECK(visibleIO->last_consumed_seed_generation == activeSeedGeneration);
  CHECK(visibleIO->last_consumed_frame_session != 0);
  CHECK(visibleIO->last_consumed_absolute_frame >= firstFrame);
  CHECK(visibleIO->last_consumed_absolute_frame < firstFrame + frameCount);
  CHECK(writerIO->operation_call_count == 1);
  CHECK(writerIO->valid_cycle_count == 1);
  CHECK(writerIO->invalid_cycle_count == 0);
  CHECK(writerIO->core_ok_count == 1);
  CHECK(writerIO->requested_frame_count == frameCount);
  CHECK(writerIO->transferred_frame_count == frameCount);
  CHECK(writerIO->gap_frame_count == 0);
  CHECK(writerIO->last_cycle_sample_frame == firstFrame);
  CHECK(writerIO->last_published_frame_seed == activeSeed);
  CHECK(writerIO->last_published_seed_generation == activeSeedGeneration);
  CHECK(writerIO->last_published_frame_session != 0);
  CHECK(writerIO->last_published_absolute_frame >= firstFrame);
  CHECK(writerIO->last_published_absolute_frame < firstFrame + frameCount);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 1);
  CHECK(snapshot.visible_input_active_count == 0);
  CHECK(snapshot.hidden_writer_active_count == 1);
  CHECK(snapshot.timeline_seed == activeSeed);
  CHECK(snapshot.seed_clear_count == 0);
  CHECK(snapshot.driver_lifecycle_sequence > bothStartedLifecycleSequence);
  const UInt64 readerStoppedLifecycleSequence =
      snapshot.driver_lifecycle_sequence;

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.active_client_count == 0);
  CHECK(snapshot.driver_started_count == 0);
  CHECK(snapshot.timeline_seed == 0);
  CHECK(snapshot.current_seed_generation == 0);
  CHECK(snapshot.anchor_host_ticks == 0);
  CHECK(snapshot.seed_create_count == 1);
  CHECK(snapshot.seed_clear_count == 1);
  CHECK(snapshot.last_cleared_seed == activeSeed);
  CHECK(snapshot.last_cleared_seed_generation == activeSeedGeneration);
  CHECK(snapshot.last_cleared_anchor_host_ticks == activeAnchor);
  CHECK(snapshot.global_start_transition_count == 2);
  CHECK(snapshot.global_stop_transition_count == 2);
  CHECK(snapshot.driver_lifecycle_sequence > readerStoppedLifecycleSequence);
  const UInt64 bothStoppedLifecycleSequence =
      snapshot.driver_lifecycle_sequence;

  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  CHECK(snapshot.driver_registered_count == 0);
  CHECK(snapshot.driver_registered_slot_bitmap == 0);
  CHECK(snapshot.driver_client_remove_attempt_count == 2);
  CHECK(snapshot.driver_client_remove_count == 2);
  CHECK(snapshot.last_driver_transition.type ==
        kOSVADiagnosticTransitionDriverClientRemoved);
  CHECK(snapshot.last_driver_transition.client_id == writer.mClientID);
  CHECK(snapshot.driver_lifecycle_sequence > bothStoppedLifecycleSequence);
  CHECK(gFakeHostState.notificationCount == 4);
  return true;
}

static bool TestDiagnosticLastCallAndEpochProvenance(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(851);
  AudioServerPlugInClientInfo writer = ClientInfo(852);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);

  Float64 sample = -1.0;
  UInt64 host = 0;
  UInt64 seed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &sample, &host, &seed),
               noErr);
  Float32 source[] = {0.0625F, -0.125F, 0.25F, -0.5F};
  Float32 destination[sizeof(source) / sizeof(source[0])] = {0};
  const UInt32 frameCount =
      (UInt32)(sizeof(source) / sizeof(source[0]));
  AudioServerPlugInIOCycleInfo outputCycle = CycleAtOutputFrame(2048.0);
  AudioServerPlugInIOCycleInfo inputCycle = CycleAtInputFrame(2048.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &outputCycle, source, NULL),
               noErr);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);

  OSVADiagnosticSnapshot firstEpoch;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &firstEpoch),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&firstEpoch));
  const UInt64 firstGeneration = firstEpoch.current_seed_generation;
  CHECK(firstGeneration == firstEpoch.timeline_seed);
  CHECK(firstEpoch.zero_timestamp[0].last_sample_frame == (UInt64)sample);
  CHECK(firstEpoch.zero_timestamp[0].last_host_ticks == host);
  CHECK(firstEpoch.zero_timestamp[0].last_seed == seed);
  CHECK(firstEpoch.io[0].last_consumed_seed_generation == firstGeneration);
  CHECK(firstEpoch.io[1].last_published_seed_generation == firstGeneration);

  const OSVADiagnosticZeroTimestampSnapshot successfulZero =
      firstEpoch.zero_timestamp[0];
  const OSVADiagnosticIOSnapshot successfulVisibleIO = firstEpoch.io[0];
  const OSVADiagnosticIOSnapshot successfulWriterIO = firstEpoch.io[1];
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);

  sample = -1.0;
  host = 0;
  seed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &sample, &host, &seed),
               kAudioHardwareIllegalOperationError);
  OSVADiagnosticSnapshot failedZero;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &failedZero),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&failedZero));
  const OSVADiagnosticZeroTimestampSnapshot *zero =
      &failedZero.zero_timestamp[0];
  CHECK(zero->call_count == successfulZero.call_count + 1);
  CHECK(zero->successful_return_count ==
        successfulZero.successful_return_count);
  CHECK(zero->failed_return_count == successfulZero.failed_return_count + 1);
  CHECK(zero->last_sample_frame == successfulZero.last_sample_frame);
  CHECK(zero->last_host_ticks == successfulZero.last_host_ticks);
  CHECK(zero->last_seed == successfulZero.last_seed);
  CHECK(zero->last_seed_generation == successfulZero.last_seed_generation);
  CHECK(zero->last_core_lifecycle_sequence ==
        successfulZero.last_core_lifecycle_sequence);
  CHECK(zero->last_call_core_lifecycle_sequence ==
        failedZero.core_lifecycle_sequence);
  CHECK(zero->last_status != 0);
  CHECK((zero->flags & kOSVADiagnosticRecordPresent) != 0);
  CHECK((zero->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0);
  CHECK((zero->flags & kOSVADiagnosticRecordLastCallValid) == 0);
  CHECK((zero->flags & kOSVADiagnosticRecordUsedFallback) == 0);
  CHECK((zero->flags & kOSVADiagnosticRecordEpochMappingValid) != 0);

  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  OSVADiagnosticSnapshot restartedBeforeTransfer;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &restartedBeforeTransfer),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&restartedBeforeTransfer));
  CHECK(restartedBeforeTransfer.current_seed_generation != 0);
  CHECK(restartedBeforeTransfer.current_seed_generation != firstGeneration);
  CHECK(restartedBeforeTransfer.current_seed_generation ==
        restartedBeforeTransfer.timeline_seed);
  CHECK((restartedBeforeTransfer.invariant_flags &
         kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed) != 0);
  CHECK((restartedBeforeTransfer.invariant_flags &
         kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration) !=
        0);
  CHECK(restartedBeforeTransfer.io[0].last_consumed_seed_generation ==
        firstGeneration);
  CHECK(restartedBeforeTransfer.io[1].last_published_seed_generation ==
        firstGeneration);

  AudioServerPlugInIOCycleInfo invalidCycle;
  memset(&invalidCycle, 0, sizeof(invalidCycle));
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &invalidCycle, source, NULL),
               noErr);
  OSVADiagnosticSnapshot invalidWriter;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &invalidWriter),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&invalidWriter));
  const OSVADiagnosticIOSnapshot *writerIO = &invalidWriter.io[1];
  CHECK(writerIO->operation_call_count ==
        successfulWriterIO.operation_call_count + 1);
  CHECK(writerIO->invalid_cycle_count ==
        successfulWriterIO.invalid_cycle_count + 1);
  CHECK(writerIO->requested_frame_count ==
        successfulWriterIO.requested_frame_count + frameCount);
  CHECK(writerIO->gap_frame_count ==
        successfulWriterIO.gap_frame_count + frameCount);
  CHECK(writerIO->last_status != 0);
  CHECK((writerIO->flags & kOSVADiagnosticRecordPresent) != 0);
  CHECK((writerIO->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0);
  CHECK((writerIO->flags & kOSVADiagnosticRecordLastCallValid) == 0);
  CHECK((writerIO->flags & kOSVADiagnosticRecordEpochMappingValid) != 0);
  CHECK(writerIO->last_published_frame_seed ==
        successfulWriterIO.last_published_frame_seed);
  CHECK(writerIO->last_published_seed_generation == firstGeneration);
  CHECK(writerIO->last_published_frame_session ==
        successfulWriterIO.last_published_frame_session);
  CHECK(writerIO->last_published_absolute_frame ==
        successfulWriterIO.last_published_absolute_frame);

  memset(destination, 0x7F, sizeof(destination));
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &invalidCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));
  OSVADiagnosticSnapshot invalidVisible;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &invalidVisible),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&invalidVisible));
  const OSVADiagnosticIOSnapshot *visibleIO = &invalidVisible.io[0];
  CHECK(visibleIO->operation_call_count ==
        successfulVisibleIO.operation_call_count + 1);
  CHECK(visibleIO->invalid_cycle_count ==
        successfulVisibleIO.invalid_cycle_count + 1);
  CHECK(visibleIO->last_status != 0);
  CHECK((visibleIO->flags & kOSVADiagnosticRecordPresent) != 0);
  CHECK((visibleIO->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0);
  CHECK((visibleIO->flags & kOSVADiagnosticRecordLastCallValid) == 0);
  CHECK((visibleIO->flags & kOSVADiagnosticRecordEpochMappingValid) != 0);
  CHECK(visibleIO->last_consumed_frame_seed ==
        successfulVisibleIO.last_consumed_frame_seed);
  CHECK(visibleIO->last_consumed_seed_generation == firstGeneration);
  CHECK(visibleIO->last_consumed_frame_session ==
        successfulVisibleIO.last_consumed_frame_session);
  CHECK(visibleIO->last_consumed_absolute_frame ==
        successfulVisibleIO.last_consumed_absolute_frame);

  outputCycle = CycleAtOutputFrame(8192.0);
  inputCycle = CycleAtInputFrame(8192.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &outputCycle, source, NULL),
               noErr);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);
  OSVADiagnosticSnapshot secondEpochTransfer;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &secondEpochTransfer),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&secondEpochTransfer));
  CHECK(secondEpochTransfer.io[0].last_consumed_seed_generation ==
        secondEpochTransfer.current_seed_generation);
  CHECK(secondEpochTransfer.io[1].last_published_seed_generation ==
        secondEpochTransfer.current_seed_generation);
  CHECK(secondEpochTransfer.io[0].last_consumed_seed_generation !=
        firstGeneration);
  CHECK(secondEpochTransfer.current_seed_generation ==
        secondEpochTransfer.timeline_seed);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  return true;
}

enum { kDriverOverflowDiagnosticFrameCount = 4096 };

static bool TestDriverIOOverflowDiagnosticsAreInitialized(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(403);
  AudioServerPlugInClientInfo writer = ClientInfo(404);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);

  const Float64 overflowStartFrame = 0x1.fffffffffffffp+63;
  CHECK((UInt64)overflowStartFrame == UINT64_MAX - UINT64_C(2047));
  Float32 source[kDriverOverflowDiagnosticFrameCount];
  Float32 destination[kDriverOverflowDiagnosticFrameCount];
  for (size_t index = 0; index < kDriverOverflowDiagnosticFrameCount;
       ++index) {
    source[index] = 0.25F;
    destination[index] = 9.0F;
  }

  AudioServerPlugInIOCycleInfo outputCycle =
      CycleAtOutputFrame(overflowStartFrame);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix,
                   kDriverOverflowDiagnosticFrameCount, &outputCycle, source,
                   NULL),
               kAudioHardwareIllegalOperationError);
  CHECK(AllSamplesEqual(source, kDriverOverflowDiagnosticFrameCount, 0.25F));

  AudioServerPlugInIOCycleInfo inputCycle =
      CycleAtInputFrame(overflowStartFrame);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   kDriverOverflowDiagnosticFrameCount, &inputCycle,
                   destination, NULL),
               kAudioHardwareIllegalOperationError);
  CHECK(AllSamplesEqual(destination, kDriverOverflowDiagnosticFrameCount,
                        0.0F));

  OSVADiagnosticSnapshot snapshot;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &snapshot),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&snapshot));
  for (size_t endpoint = 0; endpoint < 2; ++endpoint) {
    const OSVADiagnosticIOSnapshot *io = &snapshot.io[endpoint];
    CHECK(io->sequence == 1);
    CHECK(io->metadata_sequence == 2);
    CHECK(io->metadata_dropped_update_count == 0);
    CHECK(io->operation_call_count == 1);
    CHECK(io->valid_cycle_count == 1);
    CHECK(io->invalid_cycle_count == 0);
    CHECK(io->lease_unavailable_count == 0);
    CHECK(io->epoch_mapping_unavailable_count == 0);
    CHECK(io->core_ok_count == 0);
    CHECK(io->core_retry_count == 0);
    CHECK(io->core_failure_count == 1);
    CHECK(io->requested_frame_count ==
          kDriverOverflowDiagnosticFrameCount);
    CHECK(io->transferred_frame_count == 0);
    CHECK(io->last_cycle_sample_frame == (UInt64)overflowStartFrame);
    CHECK(io->last_cycle_host_ticks != 0);
    CHECK(io->last_status == (SInt32)OSVA_STATUS_INVALID_ARGUMENT);
    CHECK((io->flags & kOSVADiagnosticRecordPresent) != 0);
    CHECK((io->flags & kOSVADiagnosticRecordLastCallValid) != 0);
    CHECK((io->flags & kOSVADiagnosticRecordLastSuccessTupleValid) == 0);
    CHECK((io->flags & kOSVADiagnosticRecordEpochMappingValid) == 0);
  }

  const OSVADiagnosticIOSnapshot *visible = &snapshot.io[0];
  CHECK(visible->gap_frame_count == kDriverOverflowDiagnosticFrameCount);
  CHECK(visible->last_client_id == reader.mClientID);
  CHECK(visible->last_consumed_frame_seed == 0);
  CHECK(visible->last_consumed_seed_generation == 0);
  CHECK(visible->last_consumed_frame_session == 0);
  CHECK(visible->last_consumed_absolute_frame == 0);
  const OSVADiagnosticIOSnapshot *hidden = &snapshot.io[1];
  CHECK(hidden->gap_frame_count == 0);
  CHECK(hidden->last_client_id == writer.mClientID);
  CHECK(hidden->last_published_frame_seed == 0);
  CHECK(hidden->last_published_seed_generation == 0);
  CHECK(hidden->last_published_frame_session == 0);
  CHECK(hidden->last_published_absolute_frame == 0);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  return true;
}

static bool TestProductionIOTransferAndStaleSilence(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(401);
  AudioServerPlugInClientInfo writer = ClientInfo(402);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  Float32 source[] = {0.125F, -0.25F, 0.5F, -0.75F, 1.0F, -1.0F};
  Float32 destination[sizeof(source) / sizeof(source[0])];
  AudioServerPlugInIOCycleInfo outputCycle = CycleAtOutputFrame(512.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix,
                   (UInt32)(sizeof(source) / sizeof(source[0])), &outputCycle,
                   source, NULL),
               noErr);
  memset(destination, 0, sizeof(destination));
  AudioServerPlugInIOCycleInfo inputCycle = CycleAtInputFrame(512.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   (UInt32)(sizeof(destination) / sizeof(destination[0])),
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);

  CHECK_STATUS((*driver)->DoIOOperation(driver, kOSVAObjectIDVisibleInputDevice,
                                        kOSVAObjectIDHiddenWriterStream,
                                        reader.mClientID,
                                        kAudioServerPlugInIOOperationReadInput,
                                        1, &inputCycle, destination, NULL),
               kAudioHardwareBadStreamError);
  CHECK_STATUS((*driver)->DoIOOperation(driver, kOSVAObjectIDVisibleInputDevice,
                                        kOSVAObjectIDVisibleInputStream,
                                        reader.mClientID,
                                        kAudioServerPlugInIOOperationWriteMix,
                                        1, &inputCycle, destination, NULL),
               kAudioHardwareUnsupportedOperationError);

  for (size_t index = 0; index < sizeof(destination) / sizeof(destination[0]);
       ++index) {
    destination[index] = 9.0F;
  }
  AudioServerPlugInIOCycleInfo invalidCycle;
  memset(&invalidCycle, 0, sizeof(invalidCycle));
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   (UInt32)(sizeof(destination) / sizeof(destination[0])),
                   &invalidCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));

  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix,
                   (UInt32)(sizeof(source) / sizeof(source[0])), &invalidCycle,
                   source, NULL),
               noErr);
  inputCycle = CycleAtInputFrame(2048.0);
  for (size_t index = 0; index < sizeof(destination) / sizeof(destination[0]);
       ++index) {
    destination[index] = 9.0F;
  }
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   (UInt32)(sizeof(destination) / sizeof(destination[0])),
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));

  memset(destination, 0x7F, sizeof(destination));
  inputCycle = CycleAtInputFrame(4096.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   (UInt32)(sizeof(destination) / sizeof(destination[0])),
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));

  outputCycle = CycleAtOutputFrame(1024.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix,
                   (UInt32)(sizeof(source) / sizeof(source[0])), &outputCycle,
                   source, NULL),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  inputCycle = CycleAtInputFrame(1024.0);
  for (size_t index = 0; index < sizeof(destination) / sizeof(destination[0]);
       ++index) {
    destination[index] = 9.0F;
  }
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput,
                   (UInt32)(sizeof(destination) / sizeof(destination[0])),
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  return true;
}

static bool TestHALStyleFutureOutputFeedsLaterInputCycle(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(451);
  AudioServerPlugInClientInfo writer = ClientInfo(452);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  Float32 firstFutureOutput[] = {0.03125F, -0.0625F, 0.125F, -0.25F};
  Float32 secondFutureOutput[] = {0.5F, -0.75F, 0.875F, -1.0F};
  Float32 input[sizeof(firstFutureOutput) / sizeof(firstFutureOutput[0])];
  UInt32 frameCount =
      (UInt32)(sizeof(firstFutureOutput) / sizeof(firstFutureOutput[0]));

  AudioServerPlugInIOCycleInfo firstOutputCycle =
      CycleAtOutputFrame(1480.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &firstOutputCycle, firstFutureOutput, NULL),
               noErr);

  AudioServerPlugInIOCycleInfo firstInputCycle = CycleAtInputFrame(1000.0);
  for (size_t index = 0; index < sizeof(input) / sizeof(input[0]); ++index) {
    input[index] = 9.0F;
  }
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &firstInputCycle, input, NULL),
               noErr);
  CHECK(AllSamplesEqual(input, sizeof(input) / sizeof(input[0]), 0.0F));

  /*
   * A HAL input cycle commonly consumes the frame range that the output side
   * published in the preceding cycle. Read it before the current cycle's
   * future output write to prove callback ordering is irrelevant.
   */
  AudioServerPlugInIOCycleInfo secondInputCycle = CycleAtInputFrame(1480.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &secondInputCycle, input, NULL),
               noErr);
  CHECK(memcmp(input, firstFutureOutput, sizeof(input)) == 0);

  AudioServerPlugInIOCycleInfo secondOutputCycle =
      CycleAtOutputFrame(1960.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDHiddenWriterDevice,
                   kOSVAObjectIDHiddenWriterStream, writer.mClientID,
                   kAudioServerPlugInIOOperationWriteMix, frameCount,
                   &secondOutputCycle, secondFutureOutput, NULL),
               noErr);
  AudioServerPlugInIOCycleInfo thirdInputCycle = CycleAtInputFrame(1960.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &thirdInputCycle, input, NULL),
               noErr);
  CHECK(memcmp(input, secondFutureOutput, sizeof(input)) == 0);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  return true;
}

static bool TestLifecycleFenceFailsClosedAndRecovers(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(501);
  AudioServerPlugInClientInfo writer = ClientInfo(502);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  Float32 source[] = {0.0625F, -0.125F, 0.25F, -0.5F};
  Float32 destination[sizeof(source) / sizeof(source[0])];
  UInt32 frameCount = (UInt32)(sizeof(source) / sizeof(source[0]));

  AudioServerPlugInIOCycleInfo outputCycle = CycleAtOutputFrame(8192.0);
  CHECK_STATUS((*driver)->DoIOOperation(driver, kOSVAObjectIDHiddenWriterDevice,
                                        kOSVAObjectIDHiddenWriterStream,
                                        writer.mClientID,
                                        kAudioServerPlugInIOOperationWriteMix,
                                        frameCount, &outputCycle, source, NULL),
               noErr);

  CHECK_STATUS(OSVADriverFenceNextIOForTesting(), noErr);
  for (size_t index = 0; index < sizeof(destination) / sizeof(destination[0]);
       ++index) {
    destination[index] = 9.0F;
  }
  AudioServerPlugInIOCycleInfo inputCycle = CycleAtInputFrame(8192.0);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));

  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);

  CHECK_STATUS(OSVADriverFenceNextIOForTesting(), noErr);
  outputCycle = CycleAtOutputFrame(12288.0);
  CHECK_STATUS((*driver)->DoIOOperation(driver, kOSVAObjectIDHiddenWriterDevice,
                                        kOSVAObjectIDHiddenWriterStream,
                                        writer.mClientID,
                                        kAudioServerPlugInIOOperationWriteMix,
                                        frameCount, &outputCycle, source, NULL),
               noErr);

  inputCycle = CycleAtInputFrame(12288.0);
  for (size_t index = 0; index < sizeof(destination) / sizeof(destination[0]);
       ++index) {
    destination[index] = 9.0F;
  }
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(AllSamplesEqual(destination,
                        sizeof(destination) / sizeof(destination[0]), 0.0F));

  CHECK_STATUS((*driver)->DoIOOperation(driver, kOSVAObjectIDHiddenWriterDevice,
                                        kOSVAObjectIDHiddenWriterStream,
                                        writer.mClientID,
                                        kAudioServerPlugInIOOperationWriteMix,
                                        frameCount, &outputCycle, source, NULL),
               noErr);
  CHECK_STATUS((*driver)->DoIOOperation(
                   driver, kOSVAObjectIDVisibleInputDevice,
                   kOSVAObjectIDVisibleInputStream, reader.mClientID,
                   kAudioServerPlugInIOOperationReadInput, frameCount,
                   &inputCycle, destination, NULL),
               noErr);
  CHECK(memcmp(source, destination, sizeof(source)) == 0);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  return true;
}

static bool TestZeroTimeStampLifecycleFenceIsHidden(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(601);
  AudioServerPlugInClientInfo writer = ClientInfo(602);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                  writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  Float64 baselineSample = -1.0;
  UInt64 baselineHost = 0;
  UInt64 baselineSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &baselineSample, &baselineHost, &baselineSeed),
               noErr);
  CHECK(baselineSample >= 0.0);
  CHECK(baselineHost != 0);
  CHECK(baselineSeed != 0);

  CHECK_STATUS(OSVADriverFenceZeroTimeStampCallsForTesting(32), noErr);
  Float64 fencedSample = -1.0;
  UInt64 fencedHost = 0;
  UInt64 fencedSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDHiddenWriterDevice, writer.mClientID,
                   &fencedSample, &fencedHost, &fencedSeed),
               noErr);
  CHECK(fencedSample == baselineSample);
  CHECK(fencedHost == baselineHost);
  CHECK(fencedSeed == baselineSeed);

  CHECK_STATUS(OSVADriverFenceZeroTimeStampCallsForTesting(0), noErr);
  Float64 recoveredSample = -1.0;
  UInt64 recoveredHost = 0;
  UInt64 recoveredSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &recoveredSample, &recoveredHost, &recoveredSeed),
               noErr);
  CHECK(recoveredSample >= fencedSample);
  CHECK(recoveredHost >= fencedHost);
  CHECK(recoveredSeed == fencedSeed);

  CHECK_STATUS(OSVADriverFenceZeroTimeStampCallsForTesting(1), noErr);
  Float64 retriedSample = -1.0;
  UInt64 retriedHost = 0;
  UInt64 retriedSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDHiddenWriterDevice, writer.mClientID,
                   &retriedSample, &retriedHost, &retriedSeed),
               noErr);
  CHECK(retriedSample >= recoveredSample);
  CHECK(retriedHost >= recoveredHost);
  CHECK(retriedSeed == recoveredSeed);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  CHECK_STATUS(OSVADriverFenceZeroTimeStampCallsForTesting(32), noErr);
  Float64 restartedSample = -1.0;
  UInt64 restartedHost = 0;
  UInt64 restartedSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &restartedSample, &restartedHost, &restartedSeed),
               noErr);
  CHECK(restartedSample >= 0.0);
  CHECK(restartedHost > baselineHost);
  CHECK(restartedSeed != 0);
  CHECK(restartedSeed != baselineSeed);
  CHECK_STATUS(OSVADriverFenceZeroTimeStampCallsForTesting(0), noErr);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  return true;
}

enum { kZeroTimestampPublicationPausePollLimit = 1000000 };

typedef struct ZeroTimestampPublicationCallContext {
  AudioServerPlugInDriverRef driver;
  UInt32 clientID;
  OSStatus status;
  Float64 sample;
  UInt64 host;
  UInt64 seed;
} ZeroTimestampPublicationCallContext;

static void *PausedZeroTimestampPublicationMain(void *opaqueContext) {
  ZeroTimestampPublicationCallContext *context = opaqueContext;
  context->sample = -1.0;
  context->host = 0;
  context->seed = 0;
  context->status = (*context->driver)
                        ->GetZeroTimeStamp(
                            context->driver,
                            kOSVAObjectIDVisibleInputDevice, context->clientID,
                            &context->sample, &context->host, &context->seed);
  return NULL;
}

static bool AwaitZeroTimestampPublicationPause(void) {
  for (unsigned iteration = 0;
       iteration < kZeroTimestampPublicationPausePollLimit; ++iteration) {
    if (OSVADriverZeroTimestampPublicationIsPausedForTesting()) {
      return true;
    }
    sched_yield();
  }
  return false;
}

static bool TestZeroTimestampPublicationKeepsReturnedLifecycle(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(651);
  AudioServerPlugInClientInfo sibling = ClientInfo(652);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &sibling),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  OSVADiagnosticSnapshot before;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &before),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&before));
  CHECK(before.active_client_count == 1);
  CHECK(before.zero_timestamp[0].call_count == 0);
  const UInt64 returnedLifecycleSequence = before.core_lifecycle_sequence;

  CHECK_STATUS(OSVADriverPauseNextZeroTimestampPublicationForTesting(), noErr);
  ZeroTimestampPublicationCallContext call = {
      .driver = driver,
      .clientID = reader.mClientID,
      .status = kAudioHardwareUnspecifiedError,
  };
  pthread_t timestampThread;
  CHECK(pthread_create(&timestampThread, NULL,
                       PausedZeroTimestampPublicationMain, &call) == 0);
  const bool paused = AwaitZeroTimestampPublicationPause();
  if (!paused) {
    (void)OSVADriverResumeZeroTimestampPublicationForTesting();
    (void)pthread_join(timestampThread, NULL);
    CHECK(paused);
  }

  OSVADiagnosticSnapshot whilePaused;
  const OSStatus pausedSnapshotStatus = CopyDiagnosticSnapshot(
      driver, kOSVAObjectIDHiddenWriterDevice, &whilePaused);
  const OSStatus siblingStartStatus =
      (*driver)->StartIO(driver, kOSVAObjectIDHiddenWriterDevice,
                         sibling.mClientID);
  OSVADiagnosticSnapshot afterSiblingStart;
  const OSStatus transitionedSnapshotStatus = CopyDiagnosticSnapshot(
      driver, kOSVAObjectIDVisibleInputDevice, &afterSiblingStart);
  const OSStatus resumeStatus =
      OSVADriverResumeZeroTimestampPublicationForTesting();
  const int joinStatus = pthread_join(timestampThread, NULL);

  CHECK_STATUS(pausedSnapshotStatus, noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&whilePaused));
  CHECK(whilePaused.core_lifecycle_sequence == returnedLifecycleSequence);
  CHECK(whilePaused.zero_timestamp[0].call_count == 0);
  CHECK_STATUS(siblingStartStatus, noErr);
  CHECK_STATUS(transitionedSnapshotStatus, noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&afterSiblingStart));
  CHECK(afterSiblingStart.core_lifecycle_sequence > returnedLifecycleSequence);
  CHECK(afterSiblingStart.zero_timestamp[0].call_count == 0);
  CHECK_STATUS(resumeStatus, noErr);
  CHECK(joinStatus == 0);
  CHECK_STATUS(call.status, noErr);
  CHECK(call.sample >= 0.0);
  CHECK(call.host != 0);
  CHECK(call.seed == before.timeline_seed);

  OSVADiagnosticSnapshot published;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &published),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&published));
  const OSVADiagnosticZeroTimestampSnapshot *record =
      &published.zero_timestamp[0];
  CHECK(record->call_count == 1);
  CHECK(record->successful_return_count == 1);
  CHECK(record->failed_return_count == 0);
  CHECK(record->last_sample_frame == (UInt64)call.sample);
  CHECK(record->last_host_ticks == call.host);
  CHECK(record->last_seed == call.seed);
  CHECK(record->last_seed_generation == before.current_seed_generation);
  CHECK(record->last_core_lifecycle_sequence == returnedLifecycleSequence);
  CHECK(record->last_call_core_lifecycle_sequence ==
        returnedLifecycleSequence);
  CHECK(record->last_core_lifecycle_sequence !=
        published.core_lifecycle_sequence);
  CHECK((record->flags & kOSVADiagnosticRecordPresent) != 0);
  CHECK((record->flags & kOSVADiagnosticRecordLastSuccessTupleValid) != 0);
  CHECK((record->flags & kOSVADiagnosticRecordLastCallValid) != 0);
  CHECK((record->flags & kOSVADiagnosticRecordUsedFallback) == 0);
  CHECK((record->flags & kOSVADiagnosticRecordEpochMappingValid) != 0);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 sibling.mClientID),
               noErr);
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &sibling),
               noErr);
  return true;
}

static bool AwaitDiagnosticRecordWriterHold(void) {
  for (unsigned iteration = 0;
       iteration < kZeroTimestampPublicationPausePollLimit; ++iteration) {
    if (OSVADriverDiagnosticRecordWriterIsHeldForTesting()) {
      return true;
    }
    sched_yield();
  }
  return false;
}

typedef struct HeldDiagnosticIOContext {
  AudioServerPlugInDriverRef driver;
  UInt32 clientID;
  OSStatus status;
} HeldDiagnosticIOContext;

enum { kHeldDiagnosticFrameCount = 32 };

static void *HeldVisibleIODiagnosticMain(void *opaqueContext) {
  HeldDiagnosticIOContext *context = opaqueContext;
  Float32 samples[kHeldDiagnosticFrameCount];
  for (size_t index = 0; index < kHeldDiagnosticFrameCount; ++index) {
    samples[index] = 9.0F;
  }
  AudioServerPlugInIOCycleInfo cycle = CycleAtInputFrame(0.0);
  context->status = (*context->driver)
                        ->DoIOOperation(
                            context->driver,
                            kOSVAObjectIDVisibleInputDevice,
                            kOSVAObjectIDVisibleInputStream, context->clientID,
                            kAudioServerPlugInIOOperationReadInput,
                            kHeldDiagnosticFrameCount, &cycle, samples, NULL);
  if (context->status == noErr &&
      !AllSamplesEqual(samples, kHeldDiagnosticFrameCount, 0.0F)) {
    context->status = kAudioHardwareUnspecifiedError;
  }
  return NULL;
}

static void *HeldVisibleIOWorkLoopMetadataMain(void *opaqueContext) {
  HeldDiagnosticIOContext *context = opaqueContext;
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));
  context->status = (*context->driver)
                        ->BeginIOOperation(
                            context->driver,
                            kOSVAObjectIDVisibleInputDevice, context->clientID,
                            kAudioServerPlugInIOOperationThread, 0, &cycle);
  return NULL;
}

static bool TestDiagnosticRecordDropAccountingAndLoaderInterleaving(void) {
  enum { kForcedContendingCallCount = 3 };
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(951);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  CHECK_STATUS(OSVADriverHoldNextDiagnosticRecordWriterForTesting(
                   kOSVADriverTestDiagnosticRecordZeroTimestamp,
                   kOSVADiagnosticEndpointVisibleInput),
               noErr);
  ZeroTimestampPublicationCallContext zeroCall = {
      .driver = driver,
      .clientID = reader.mClientID,
      .status = kAudioHardwareUnspecifiedError,
  };
  pthread_t zeroThread;
  CHECK(pthread_create(&zeroThread, NULL, PausedZeroTimestampPublicationMain,
                       &zeroCall) == 0);
  const bool zeroHeld = AwaitDiagnosticRecordWriterHold();
  if (!zeroHeld) {
    (void)OSVADriverResumeDiagnosticRecordWriterForTesting();
    (void)pthread_join(zeroThread, NULL);
    CHECK(zeroHeld);
  }
  OSStatus contendingZeroStatuses[kForcedContendingCallCount];
  for (size_t index = 0; index < kForcedContendingCallCount; ++index) {
    Float64 sample = -1.0;
    UInt64 host = 0;
    UInt64 seed = 0;
    contendingZeroStatuses[index] = (*driver)->GetZeroTimeStamp(
        driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID, &sample,
        &host, &seed);
  }
  const OSStatus zeroResumeStatus =
      OSVADriverResumeDiagnosticRecordWriterForTesting();
  const int zeroJoinStatus = pthread_join(zeroThread, NULL);
  CHECK_STATUS(zeroResumeStatus, noErr);
  CHECK(zeroJoinStatus == 0);
  CHECK_STATUS(zeroCall.status, noErr);
  for (size_t index = 0; index < kForcedContendingCallCount; ++index) {
    CHECK_STATUS(contendingZeroStatuses[index], noErr);
  }
  OSVADiagnosticSnapshot zeroDrops;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &zeroDrops),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&zeroDrops));
  CHECK(zeroDrops.zero_timestamp[0].metadata_dropped_update_count ==
        kForcedContendingCallCount);
  CHECK(zeroDrops.zero_timestamp[0].call_count ==
        UINT64_C(1) + kForcedContendingCallCount);
  CHECK((zeroDrops.zero_timestamp[0].metadata_sequence / UINT64_C(2)) +
            zeroDrops.zero_timestamp[0].metadata_dropped_update_count ==
        zeroDrops.zero_timestamp[0].call_count);
  CHECK(zeroDrops.zero_timestamp[0].successful_return_count ==
        zeroDrops.zero_timestamp[0].call_count);

  CHECK_STATUS(OSVADriverHoldNextDiagnosticRecordWriterForTesting(
                   kOSVADriverTestDiagnosticRecordIO,
                   kOSVADiagnosticEndpointVisibleInput),
               noErr);
  HeldDiagnosticIOContext ioCall = {
      .driver = driver,
      .clientID = reader.mClientID,
      .status = kAudioHardwareUnspecifiedError,
  };
  pthread_t ioThread;
  CHECK(pthread_create(&ioThread, NULL, HeldVisibleIODiagnosticMain, &ioCall) ==
        0);
  const bool ioHeld = AwaitDiagnosticRecordWriterHold();
  if (!ioHeld) {
    (void)OSVADriverResumeDiagnosticRecordWriterForTesting();
    (void)pthread_join(ioThread, NULL);
    CHECK(ioHeld);
  }
  OSStatus contendingIOStatuses[kForcedContendingCallCount];
  for (size_t iteration = 0; iteration < kForcedContendingCallCount;
       ++iteration) {
    Float32 samples[kHeldDiagnosticFrameCount];
    for (size_t index = 0; index < kHeldDiagnosticFrameCount; ++index) {
      samples[index] = 9.0F;
    }
    AudioServerPlugInIOCycleInfo cycle = CycleAtInputFrame(
        (Float64)(iteration + 1) * (Float64)kHeldDiagnosticFrameCount);
    contendingIOStatuses[iteration] = (*driver)->DoIOOperation(
        driver, kOSVAObjectIDVisibleInputDevice,
        kOSVAObjectIDVisibleInputStream, reader.mClientID,
        kAudioServerPlugInIOOperationReadInput, kHeldDiagnosticFrameCount,
        &cycle, samples, NULL);
    if (contendingIOStatuses[iteration] == noErr &&
        !AllSamplesEqual(samples, kHeldDiagnosticFrameCount, 0.0F)) {
      contendingIOStatuses[iteration] = kAudioHardwareUnspecifiedError;
    }
  }
  const OSStatus ioResumeStatus =
      OSVADriverResumeDiagnosticRecordWriterForTesting();
  const int ioJoinStatus = pthread_join(ioThread, NULL);
  CHECK_STATUS(ioResumeStatus, noErr);
  CHECK(ioJoinStatus == 0);
  CHECK_STATUS(ioCall.status, noErr);
  for (size_t index = 0; index < kForcedContendingCallCount; ++index) {
    CHECK_STATUS(contendingIOStatuses[index], noErr);
  }
  OSVADiagnosticSnapshot ioDrops;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &ioDrops),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&ioDrops));
  CHECK(ioDrops.io[0].metadata_dropped_update_count ==
        kForcedContendingCallCount);
  CHECK(ioDrops.io[0].operation_call_count ==
        UINT64_C(1) + kForcedContendingCallCount);
  CHECK((ioDrops.io[0].metadata_sequence / UINT64_C(2)) +
            ioDrops.io[0].metadata_dropped_update_count ==
        ioDrops.io[0].operation_call_count);

  CHECK_STATUS(OSVADriverHoldNextDiagnosticRecordWriterForTesting(
                   kOSVADriverTestDiagnosticRecordIOWorkLoopMetadata,
                   kOSVADiagnosticEndpointVisibleInput),
               noErr);
  HeldDiagnosticIOContext workLoopCall = {
      .driver = driver,
      .clientID = 961,
      .status = kAudioHardwareUnspecifiedError,
  };
  pthread_t workLoopThread;
  CHECK(pthread_create(&workLoopThread, NULL,
                       HeldVisibleIOWorkLoopMetadataMain, &workLoopCall) == 0);
  const bool workLoopHeld = AwaitDiagnosticRecordWriterHold();
  if (!workLoopHeld) {
    (void)OSVADriverResumeDiagnosticRecordWriterForTesting();
    (void)pthread_join(workLoopThread, NULL);
    CHECK(workLoopHeld);
  }
  OSVADiagnosticSnapshot unavailableSnapshot;
  const OSStatus heldReadStatus = CopyDiagnosticSnapshot(
      driver, kOSVAObjectIDVisibleInputDevice, &unavailableSnapshot);
  AudioServerPlugInIOCycleInfo cycle;
  memset(&cycle, 0, sizeof(cycle));
  const OSStatus nestedBeginStatus = (*driver)->BeginIOOperation(
      driver, kOSVAObjectIDVisibleInputDevice, 962,
      kAudioServerPlugInIOOperationThread, 0, &cycle);
  const OSStatus nestedEndStatus = (*driver)->EndIOOperation(
      driver, kOSVAObjectIDVisibleInputDevice, 962,
      kAudioServerPlugInIOOperationThread, 0, &cycle);
  const OSStatus workLoopResumeStatus =
      OSVADriverResumeDiagnosticRecordWriterForTesting();
  const int workLoopJoinStatus = pthread_join(workLoopThread, NULL);
  const OSStatus finalEndStatus = (*driver)->EndIOOperation(
      driver, kOSVAObjectIDVisibleInputDevice, 961,
      kAudioServerPlugInIOOperationThread, 0, &cycle);
  CHECK_STATUS(heldReadStatus, kOSVADiagnosticSnapshotUnavailableError);
  CHECK_STATUS(nestedBeginStatus, noErr);
  CHECK_STATUS(nestedEndStatus, noErr);
  CHECK_STATUS(workLoopResumeStatus, noErr);
  CHECK(workLoopJoinStatus == 0);
  CHECK_STATUS(workLoopCall.status, noErr);
  CHECK_STATUS(finalEndStatus, noErr);

  OSVADiagnosticSnapshot workLoopDrops;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &workLoopDrops),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&workLoopDrops));
  const OSVADiagnosticIOWorkLoopSnapshot *workLoop =
      &workLoopDrops.io_work_loop[0];
  CHECK(workLoop->sequence == 4);
  CHECK(workLoop->metadata_sequence == 4);
  CHECK(workLoop->metadata_dropped_update_count == 2);
  CHECK(workLoop->current_count == 0);
  CHECK(workLoop->begin_count == 2);
  CHECK(workLoop->end_count == 2);
  CHECK(workLoop->underflow_count == 0);
  CHECK(workLoop->last_client_id == 961);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  return true;
}

enum {
  kWrapperLifecycleStressIterations = 2000,
  kWrapperCallbackStressIterations = 8000,
  kWrapperMinimumSuccessfulTimestampReturns =
      kWrapperCallbackStressIterations / 2,
  kWrapperCallbackStressFrameCount = 32,
};

typedef struct WrapperLifecycleStressContext {
  AudioServerPlugInDriverRef driver;
  UInt32 readerClientID;
  UInt32 writerClientID;
  UInt64 expectedSeed;
  _Atomic bool start;
  _Atomic unsigned failureCount;
  _Atomic UInt64 successfulTimestampReturnCount;
  _Atomic UInt64 boundedTimestampMissCount;
} WrapperLifecycleStressContext;

static void WrapperStressRecordFailure(
    WrapperLifecycleStressContext *context) {
  (void)atomic_fetch_add_explicit(&context->failureCount, 1,
                                  memory_order_relaxed);
}

static void WrapperStressAwaitStart(
    const WrapperLifecycleStressContext *context) {
  while (!atomic_load_explicit(&context->start, memory_order_acquire)) {
  }
}

static void *WrapperLifecycleStressMain(void *opaqueContext) {
  WrapperLifecycleStressContext *context = opaqueContext;
  WrapperStressAwaitStart(context);
  for (unsigned iteration = 0; iteration < kWrapperLifecycleStressIterations;
       ++iteration) {
    if ((*context->driver)
            ->StartIO(context->driver, kOSVAObjectIDHiddenWriterDevice,
                      context->writerClientID) != noErr) {
      WrapperStressRecordFailure(context);
      return NULL;
    }
    if ((*context->driver)
            ->StopIO(context->driver, kOSVAObjectIDHiddenWriterDevice,
                     context->writerClientID) != noErr) {
      WrapperStressRecordFailure(context);
      return NULL;
    }
  }
  return NULL;
}

static void *WrapperReadInputStressMain(void *opaqueContext) {
  WrapperLifecycleStressContext *context = opaqueContext;
  WrapperStressAwaitStart(context);
  Float32 samples[kWrapperCallbackStressFrameCount];
  for (unsigned iteration = 0; iteration < kWrapperCallbackStressIterations;
       ++iteration) {
    for (size_t index = 0; index < kWrapperCallbackStressFrameCount; ++index) {
      samples[index] = 9.0F;
    }
    AudioServerPlugInIOCycleInfo cycle =
        CycleAtInputFrame((Float64)iteration *
                          (Float64)kWrapperCallbackStressFrameCount);
    OSStatus status = (*context->driver)
                          ->DoIOOperation(
                              context->driver,
                              kOSVAObjectIDVisibleInputDevice,
                              kOSVAObjectIDVisibleInputStream,
                              context->readerClientID,
                              kAudioServerPlugInIOOperationReadInput,
                              kWrapperCallbackStressFrameCount, &cycle,
                              samples, NULL);
    if (status != noErr ||
        !AllSamplesEqual(samples, kWrapperCallbackStressFrameCount, 0.0F)) {
      WrapperStressRecordFailure(context);
      return NULL;
    }
  }
  return NULL;
}

static void *WrapperZeroTimeStampStressMain(void *opaqueContext) {
  WrapperLifecycleStressContext *context = opaqueContext;
  WrapperStressAwaitStart(context);
  Float64 previousSample = -1.0;
  UInt64 previousHost = 0;
  UInt64 successfulTimestampReturns = 0;
  UInt64 boundedTimestampMisses = 0;
  for (unsigned iteration = 0; iteration < kWrapperCallbackStressIterations;
       ++iteration) {
    Float64 sample = -1.0;
    UInt64 host = 0;
    UInt64 seed = 0;
    const OSStatus status =
        (*context->driver)
            ->GetZeroTimeStamp(context->driver,
                               kOSVAObjectIDVisibleInputDevice,
                               context->readerClientID, &sample, &host, &seed);
    if (status == noErr) {
      if (seed != context->expectedSeed || sample < 0.0 ||
          fmod(sample, (Float64)kOSVAZeroTimeStampPeriodFrames) != 0.0 ||
          host == 0 || sample < previousSample || host < previousHost) {
        WrapperStressRecordFailure(context);
        return NULL;
      }
      previousSample = sample;
      previousHost = host;
      successfulTimestampReturns += 1;
    } else if (status == kAudioHardwareUnspecifiedError) {
      boundedTimestampMisses += 1;
    } else {
      WrapperStressRecordFailure(context);
      return NULL;
    }
  }
  if (successfulTimestampReturns <
      kWrapperMinimumSuccessfulTimestampReturns) {
    WrapperStressRecordFailure(context);
    return NULL;
  }
  (void)atomic_fetch_add_explicit(&context->successfulTimestampReturnCount,
                                  successfulTimestampReturns,
                                  memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&context->boundedTimestampMissCount,
                                  boundedTimestampMisses,
                                  memory_order_relaxed);
  return NULL;
}

static bool TestConcurrentSiblingLifecycleBoundsCallbackMisses(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(701);
  AudioServerPlugInClientInfo writer = ClientInfo(702);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  Float64 initialSample = -1.0;
  UInt64 initialHost = 0;
  UInt64 initialSeed = 0;
  CHECK_STATUS((*driver)->GetZeroTimeStamp(
                   driver, kOSVAObjectIDVisibleInputDevice, reader.mClientID,
                   &initialSample, &initialHost, &initialSeed),
               noErr);
  CHECK(initialSeed != 0);

  WrapperLifecycleStressContext context = {
      .driver = driver,
      .readerClientID = reader.mClientID,
      .writerClientID = writer.mClientID,
      .expectedSeed = initialSeed,
  };
  atomic_init(&context.start, false);
  atomic_init(&context.failureCount, 0);
  atomic_init(&context.successfulTimestampReturnCount, 0);
  atomic_init(&context.boundedTimestampMissCount, 0);

  pthread_t lifecycleThread;
  pthread_t readThread;
  pthread_t timestampThread;
  CHECK(pthread_create(&lifecycleThread, NULL, WrapperLifecycleStressMain,
                       &context) == 0);
  CHECK(pthread_create(&readThread, NULL, WrapperReadInputStressMain,
                       &context) == 0);
  CHECK(pthread_create(&timestampThread, NULL,
                       WrapperZeroTimeStampStressMain, &context) == 0);
  atomic_store_explicit(&context.start, true, memory_order_release);
  CHECK(pthread_join(lifecycleThread, NULL) == 0);
  CHECK(pthread_join(readThread, NULL) == 0);
  CHECK(pthread_join(timestampThread, NULL) == 0);
  CHECK(atomic_load_explicit(&context.failureCount, memory_order_relaxed) == 0);
  const UInt64 observedTimestampSuccesses = atomic_load_explicit(
      &context.successfulTimestampReturnCount, memory_order_relaxed);
  const UInt64 observedTimestampMisses = atomic_load_explicit(
      &context.boundedTimestampMissCount, memory_order_relaxed);
  CHECK(observedTimestampSuccesses + observedTimestampMisses ==
        kWrapperCallbackStressIterations);

  OSVADiagnosticSnapshot finalActive;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &finalActive),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&finalActive));
  CHECK(finalActive.zero_timestamp[0].call_count ==
        UINT64_C(1) + kWrapperCallbackStressIterations);
  CHECK(finalActive.zero_timestamp[0].successful_return_count ==
        UINT64_C(1) + observedTimestampSuccesses);
  CHECK(finalActive.zero_timestamp[0].failed_return_count ==
        observedTimestampMisses);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  return true;
}

enum {
  kDiagnosticLifecycleStressIterations = 1500,
  kDiagnosticCallbackStressIterations = 6000,
  kDiagnosticCallbackStressThreadCount = 3,
  kDiagnosticMinimumSuccessfulTimestampReturnsPerThread =
      kDiagnosticCallbackStressIterations / 2,
  kDiagnosticSnapshotStressIterations = 8000,
  kDiagnosticStressFrameCount = 32,
};

typedef struct DiagnosticSnapshotStressContext {
  AudioServerPlugInDriverRef driver;
  UInt32 readerClientID;
  UInt32 writerClientID;
  UInt64 expectedSeed;
  UInt64 expectedDriverInstanceGeneration;
  _Atomic bool start;
  _Atomic unsigned failureCount;
  _Atomic UInt64 successfulTimestampReturnCount;
  _Atomic UInt64 boundedTimestampMissCount;
  _Atomic UInt64 successfulSnapshotReadCount;
  _Atomic UInt64 unavailableSnapshotReadCount;
} DiagnosticSnapshotStressContext;

static void DiagnosticStressRecordFailure(
    DiagnosticSnapshotStressContext *context) {
  (void)atomic_fetch_add_explicit(&context->failureCount, 1,
                                  memory_order_relaxed);
}

static void DiagnosticStressAwaitStart(
    const DiagnosticSnapshotStressContext *context) {
  while (!atomic_load_explicit(&context->start, memory_order_acquire)) {
    sched_yield();
  }
}

static void *DiagnosticLifecycleStressMain(void *opaqueContext) {
  DiagnosticSnapshotStressContext *context = opaqueContext;
  DiagnosticStressAwaitStart(context);
  for (unsigned iteration = 0;
       iteration < kDiagnosticLifecycleStressIterations; ++iteration) {
    if ((*context->driver)
            ->StartIO(context->driver, kOSVAObjectIDHiddenWriterDevice,
                      context->writerClientID) != noErr ||
        (*context->driver)
                ->StopIO(context->driver, kOSVAObjectIDHiddenWriterDevice,
                         context->writerClientID) != noErr) {
      DiagnosticStressRecordFailure(context);
      return NULL;
    }
    if ((iteration & 31U) == 0) {
      sched_yield();
    }
  }
  return NULL;
}

static void *DiagnosticCallbackStressMain(void *opaqueContext) {
  DiagnosticSnapshotStressContext *context = opaqueContext;
  DiagnosticStressAwaitStart(context);
  Float32 samples[kDiagnosticStressFrameCount];
  UInt64 successfulTimestampReturns = 0;
  UInt64 boundedTimestampMisses = 0;
  for (unsigned iteration = 0;
       iteration < kDiagnosticCallbackStressIterations; ++iteration) {
    Float64 sample = -1.0;
    UInt64 host = 0;
    UInt64 seed = 0;
    const OSStatus timestampStatus =
        (*context->driver)
            ->GetZeroTimeStamp(
                context->driver, kOSVAObjectIDVisibleInputDevice,
                context->readerClientID, &sample, &host, &seed);
    if (timestampStatus == noErr) {
      if (sample < 0.0 || host == 0 || seed != context->expectedSeed) {
        DiagnosticStressRecordFailure(context);
        return NULL;
      }
      successfulTimestampReturns += 1;
    } else if (timestampStatus == kAudioHardwareUnspecifiedError) {
      boundedTimestampMisses += 1;
    } else {
      DiagnosticStressRecordFailure(context);
      return NULL;
    }

    for (size_t index = 0; index < kDiagnosticStressFrameCount; ++index) {
      samples[index] = 9.0F;
    }
    AudioServerPlugInIOCycleInfo cycle = CycleAtInputFrame(
        (Float64)iteration * (Float64)kDiagnosticStressFrameCount);
    if ((*context->driver)
                ->DoIOOperation(
                    context->driver, kOSVAObjectIDVisibleInputDevice,
                    kOSVAObjectIDVisibleInputStream, context->readerClientID,
                    kAudioServerPlugInIOOperationReadInput,
                    kDiagnosticStressFrameCount, &cycle, samples, NULL) !=
            noErr ||
        !AllSamplesEqual(samples, kDiagnosticStressFrameCount, 0.0F)) {
      DiagnosticStressRecordFailure(context);
      return NULL;
    }
  }
  if (successfulTimestampReturns <
      kDiagnosticMinimumSuccessfulTimestampReturnsPerThread) {
    DiagnosticStressRecordFailure(context);
    return NULL;
  }
  (void)atomic_fetch_add_explicit(&context->successfulTimestampReturnCount,
                                  successfulTimestampReturns,
                                  memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&context->boundedTimestampMissCount,
                                  boundedTimestampMisses,
                                  memory_order_relaxed);
  return NULL;
}

typedef struct DiagnosticSnapshotReaderThreadContext {
  DiagnosticSnapshotStressContext *shared;
  AudioObjectID deviceObjectID;
} DiagnosticSnapshotReaderThreadContext;

static void *DiagnosticSnapshotReaderStressMain(void *opaqueContext) {
  DiagnosticSnapshotReaderThreadContext *readerContext = opaqueContext;
  DiagnosticSnapshotStressContext *context = readerContext->shared;
  DiagnosticStressAwaitStart(context);
  UInt64 previousSequence = 0;
  UInt64 previousCapturedHostTicks = 0;
  UInt64 successfulReads = 0;
  UInt64 unavailableReads = 0;
  for (unsigned iteration = 0;
       iteration < kDiagnosticSnapshotStressIterations; ++iteration) {
    OSVADiagnosticSnapshot snapshot;
    const OSStatus status = CopyDiagnosticSnapshot(
        context->driver, readerContext->deviceObjectID, &snapshot);
    if (status == kOSVADiagnosticSnapshotUnavailableError) {
      unavailableReads += 1;
      sched_yield();
      continue;
    }
    if (status != noErr || !DiagnosticSnapshotIsCoherent(&snapshot) ||
        snapshot.driver_instance_generation !=
            context->expectedDriverInstanceGeneration ||
        snapshot.snapshot_sequence <= previousSequence ||
        snapshot.captured_host_ticks < previousCapturedHostTicks ||
        snapshot.visible_input_active_count != 1 ||
        snapshot.hidden_writer_active_count > 1) {
      DiagnosticStressRecordFailure(context);
      return NULL;
    }
    previousSequence = snapshot.snapshot_sequence;
    previousCapturedHostTicks = snapshot.captured_host_ticks;
    successfulReads += 1;
  }
  if (successfulReads == 0) {
    DiagnosticStressRecordFailure(context);
    return NULL;
  }
  (void)atomic_fetch_add_explicit(&context->successfulSnapshotReadCount,
                                  successfulReads, memory_order_relaxed);
  (void)atomic_fetch_add_explicit(&context->unavailableSnapshotReadCount,
                                  unavailableReads, memory_order_relaxed);
  return NULL;
}

static bool TestDiagnosticSnapshotConcurrentCoherencyAndProgress(void) {
  AudioServerPlugInDriverRef driver = FreshDriver();
  CHECK(driver != NULL);
  AudioServerPlugInClientInfo reader = ClientInfo(901);
  AudioServerPlugInClientInfo writer = ClientInfo(902);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->AddDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  CHECK_STATUS((*driver)->StartIO(driver, kOSVAObjectIDVisibleInputDevice,
                                  reader.mClientID),
               noErr);

  OSVADiagnosticSnapshot initial;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &initial),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&initial));
  CHECK(initial.active_client_count == 1);
  CHECK(initial.timeline_seed != 0);

  DiagnosticSnapshotStressContext context = {
      .driver = driver,
      .readerClientID = reader.mClientID,
      .writerClientID = writer.mClientID,
      .expectedSeed = initial.timeline_seed,
      .expectedDriverInstanceGeneration = initial.driver_instance_generation,
  };
  atomic_init(&context.start, false);
  atomic_init(&context.failureCount, 0);
  atomic_init(&context.successfulTimestampReturnCount, 0);
  atomic_init(&context.boundedTimestampMissCount, 0);
  atomic_init(&context.successfulSnapshotReadCount, 0);
  atomic_init(&context.unavailableSnapshotReadCount, 0);
  DiagnosticSnapshotReaderThreadContext visibleSnapshotContext = {
      .shared = &context,
      .deviceObjectID = kOSVAObjectIDVisibleInputDevice,
  };
  DiagnosticSnapshotReaderThreadContext writerSnapshotContext = {
      .shared = &context,
      .deviceObjectID = kOSVAObjectIDHiddenWriterDevice,
  };

  pthread_t lifecycleThread;
  pthread_t callbackThreads[kDiagnosticCallbackStressThreadCount];
  pthread_t visibleSnapshotThread;
  pthread_t writerSnapshotThread;
  CHECK(pthread_create(&lifecycleThread, NULL, DiagnosticLifecycleStressMain,
                       &context) == 0);
  for (size_t index = 0; index < kDiagnosticCallbackStressThreadCount;
       ++index) {
    CHECK(pthread_create(&callbackThreads[index], NULL,
                         DiagnosticCallbackStressMain, &context) == 0);
  }
  CHECK(pthread_create(&visibleSnapshotThread, NULL,
                       DiagnosticSnapshotReaderStressMain,
                       &visibleSnapshotContext) == 0);
  CHECK(pthread_create(&writerSnapshotThread, NULL,
                       DiagnosticSnapshotReaderStressMain,
                       &writerSnapshotContext) == 0);
  atomic_store_explicit(&context.start, true, memory_order_release);
  CHECK(pthread_join(lifecycleThread, NULL) == 0);
  for (size_t index = 0; index < kDiagnosticCallbackStressThreadCount;
       ++index) {
    CHECK(pthread_join(callbackThreads[index], NULL) == 0);
  }
  CHECK(pthread_join(visibleSnapshotThread, NULL) == 0);
  CHECK(pthread_join(writerSnapshotThread, NULL) == 0);
  CHECK(atomic_load_explicit(&context.failureCount, memory_order_relaxed) == 0);
  CHECK(atomic_load_explicit(&context.successfulSnapshotReadCount,
                             memory_order_relaxed) >= 2);
  const UInt64 attemptedSnapshotReads =
      UINT64_C(2) * kDiagnosticSnapshotStressIterations;
  CHECK(atomic_load_explicit(&context.successfulSnapshotReadCount,
                             memory_order_relaxed) +
            atomic_load_explicit(&context.unavailableSnapshotReadCount,
                                 memory_order_relaxed) ==
        attemptedSnapshotReads);

  OSVADiagnosticSnapshot finalActive;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDHiddenWriterDevice,
                                      &finalActive),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&finalActive));
  CHECK(finalActive.active_client_count == 1);
  CHECK(finalActive.visible_input_active_count == 1);
  CHECK(finalActive.hidden_writer_active_count == 0);
  CHECK(finalActive.timeline_seed == initial.timeline_seed);
  CHECK(finalActive.current_seed_generation ==
        initial.current_seed_generation);
  CHECK(finalActive.global_start_transition_count ==
        UINT64_C(1) + kDiagnosticLifecycleStressIterations);
  CHECK(finalActive.global_stop_transition_count ==
        kDiagnosticLifecycleStressIterations);
  const UInt64 callbackAttemptCount =
      (UInt64)kDiagnosticCallbackStressThreadCount *
      kDiagnosticCallbackStressIterations;
  const UInt64 observedTimestampSuccesses = atomic_load_explicit(
      &context.successfulTimestampReturnCount, memory_order_relaxed);
  const UInt64 observedTimestampMisses = atomic_load_explicit(
      &context.boundedTimestampMissCount, memory_order_relaxed);
  CHECK(observedTimestampSuccesses + observedTimestampMisses ==
        callbackAttemptCount);
  CHECK(observedTimestampSuccesses >=
        (UInt64)kDiagnosticCallbackStressThreadCount *
            kDiagnosticMinimumSuccessfulTimestampReturnsPerThread);
  CHECK(finalActive.zero_timestamp[0].call_count == callbackAttemptCount);
  CHECK((finalActive.zero_timestamp[0].metadata_sequence / UINT64_C(2)) +
            finalActive.zero_timestamp[0].metadata_dropped_update_count ==
        callbackAttemptCount);
  CHECK(finalActive.zero_timestamp[0].successful_return_count ==
        observedTimestampSuccesses);
  CHECK(finalActive.zero_timestamp[0].failed_return_count ==
        observedTimestampMisses);
  CHECK(finalActive.zero_timestamp[1].call_count == 0);
  CHECK(finalActive.io[0].operation_call_count == callbackAttemptCount);
  CHECK((finalActive.io[0].metadata_sequence / UINT64_C(2)) +
            finalActive.io[0].metadata_dropped_update_count ==
        callbackAttemptCount);
  CHECK(finalActive.io[0].valid_cycle_count ==
        finalActive.io[0].operation_call_count);
  CHECK(finalActive.io[0].invalid_cycle_count == 0);
  CHECK(finalActive.io[0].core_ok_count +
            finalActive.io[0].core_retry_count +
            finalActive.io[0].lease_unavailable_count ==
        finalActive.io[0].operation_call_count);
  CHECK(finalActive.io[0].core_failure_count == 0);
  CHECK(finalActive.io[0].requested_frame_count ==
        finalActive.io[0].operation_call_count *
            kDiagnosticStressFrameCount);
  CHECK(finalActive.io[0].transferred_frame_count == 0);
  CHECK(finalActive.io[0].gap_frame_count ==
        finalActive.io[0].requested_frame_count);
  CHECK(finalActive.io[1].operation_call_count == 0);

  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDVisibleInputDevice,
                                 reader.mClientID),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDVisibleInputDevice, &reader),
               noErr);
  CHECK_STATUS((*driver)->RemoveDeviceClient(
                   driver, kOSVAObjectIDHiddenWriterDevice, &writer),
               noErr);
  OSVADiagnosticSnapshot finalIdle;
  CHECK_STATUS(CopyDiagnosticSnapshot(driver, kOSVAObjectIDVisibleInputDevice,
                                      &finalIdle),
               noErr);
  CHECK(DiagnosticSnapshotIsCoherent(&finalIdle));
  CHECK(finalIdle.active_client_count == 0);
  CHECK(finalIdle.driver_registered_count == 0);
  CHECK(finalIdle.seed_create_count == finalIdle.seed_clear_count);
  CHECK(finalIdle.global_start_transition_count ==
        finalIdle.global_stop_transition_count);
  return true;
}

int main(void) {
  const struct {
    const char *name;
    bool (*run)(void);
  } tests[] = {
      {"factory and COM interface", TestFactoryAndCOMInterface},
      {"diagnostic snapshot property contract",
       TestDiagnosticSnapshotPropertyContract},
      {"plug-in and UID translation", TestPluginAndUIDTranslation},
      {"role-scoped topology", TestRoleScopedTopology},
      {"role-scoped stream configuration",
       TestRoleScopedStreamConfiguration},
      {"device identity, visibility, and defaults",
       TestDeviceIdentityVisibilityAndDefaults},
      {"mono formats and clock contract", TestMonoFormatsAndClockContract},
      {"read-only unity controls", TestReadOnlyUnityControls},
      {"property error contract", TestPropertyErrorContract},
      {"object class and ownership matrix", TestObjectClassAndOwnershipMatrix},
      {"exact I/O operation advertisement", TestExactIOOperationAdvertisement},
      {"I/O work-loop diagnostic bookkeeping",
       TestIOWorkLoopDiagnosticBookkeeping},
      {"I/O work-loop current-count drop accounting",
       TestIOWorkLoopCurrentCountDropAccounting},
      {"shared timeline both start orders and restart seed",
       TestSharedTimelineBothStartOrdersAndRestartSeed},
      {"seed generation driver-instance disambiguation",
       TestSeedGenerationDriverInstanceDisambiguation},
      {"client lifecycle and running notifications",
       TestClientLifecycleAndRunningNotifications},
      {"production I/O transfer and stale silence",
       TestProductionIOTransferAndStaleSilence},
      {"diagnostic snapshot lifecycle and audio records",
       TestDiagnosticSnapshotLifecycleAndAudioRecords},
      {"diagnostic last-call and epoch provenance",
       TestDiagnosticLastCallAndEpochProvenance},
      {"driver I/O overflow diagnostics are initialized",
       TestDriverIOOverflowDiagnosticsAreInitialized},
      {"HAL-style future output feeds later input cycle",
       TestHALStyleFutureOutputFeedsLaterInputCycle},
      {"lifecycle fence fails closed and recovers",
       TestLifecycleFenceFailsClosedAndRecovers},
      {"zero timestamp lifecycle fence is hidden",
       TestZeroTimeStampLifecycleFenceIsHidden},
      {"zero timestamp publication keeps returned lifecycle",
       TestZeroTimestampPublicationKeepsReturnedLifecycle},
      {"diagnostic record drop accounting and loader interleaving",
       TestDiagnosticRecordDropAccountingAndLoaderInterleaving},
      {"concurrent sibling lifecycle bounds callback misses",
       TestConcurrentSiblingLifecycleBoundsCallbackMisses},
      {"diagnostic snapshot concurrent coherency and progress",
       TestDiagnosticSnapshotConcurrentCoherencyAndProgress},
  };
  size_t passed = 0;
  for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); ++index) {
    if (!tests[index].run()) {
      fprintf(stderr, "FAILED: %s\n", tests[index].name);
      return 1;
    }
    printf("PASS: %s\n", tests[index].name);
    passed += 1;
  }
  printf("PASS: %zu/%zu production driver interface tests\n", passed,
         sizeof(tests) / sizeof(tests[0]));
  return 0;
}
