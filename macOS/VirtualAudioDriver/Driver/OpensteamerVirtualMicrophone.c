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

#define OSVA_DRIVER_CLIENT_SLOT_COUNT ((size_t)64)
#define OSVA_ZERO_TIMESTAMP_RETRY_LIMIT 8U
#define OSVA_TIMESTAMP_CACHE_ATTEMPT_LIMIT 16U

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
} OSVAZeroTimestampCache;

static OSVAZeroTimestampCache gZeroTimestampCache;
#if defined(OSVA_DRIVER_TESTING)
static _Atomic(bool) gFenceNextIOForTesting = false;
static _Atomic(uint32_t) gFenceZeroTimeStampCallCountForTesting = 0;
static bool OSVABeginLifecycleFenceForTesting(uint64_t *oddSequenceOut);
static void OSVAEndLifecycleFenceForTesting(uint64_t oddSequence);
#endif

typedef struct {
  bool registered;
  bool started;
  AudioObjectID device_object_id;
  UInt32 client_id;
  OSVAClientLease lease;
} OSVADriverClient;

static OSVADriverClient gDriverClients[OSVA_DRIVER_CLIENT_SLOT_COUNT];

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
  (void)clientID;
  (void)operationID;
  (void)ioBufferFrameSize;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  return ioCycleInfo != NULL ? noErr : kAudioHardwareIllegalOperationError;
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
      !atomic_is_lock_free(&gZeroTimestampCache.seed)) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareUnspecifiedError;
  }

  memset(&gCore, 0, sizeof(gCore));
  memset(gCoreClients, 0, sizeof(gCoreClients));
  memset(gRingStorage, 0, sizeof(gRingStorage));
  memset(gDriverClients, 0, sizeof(gDriverClients));
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
    };
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
  (void)clientID;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!gCoreInitialized) {
    return kAudioHardwareIllegalOperationError;
  }
  OSVAStatus status = OSVA_STATUS_RETRY;
  OSVAZeroTimestamp timestamp = {0};
  for (unsigned attempt = 0; attempt < OSVA_ZERO_TIMESTAMP_RETRY_LIMIT;
       ++attempt) {
    status = OSVAGetCoreZeroTimestamp(&timestamp);
    if (status == OSVA_STATUS_OK) {
      (void)OSVAStoreZeroTimestampCache(timestamp);
      *outSampleTime = (Float64)timestamp.sample_frame;
      *outHostTime = timestamp.host_ticks;
      *outSeed = timestamp.seed;
      return noErr;
    }
    if (status != OSVA_STATUS_RETRY) {
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
    *outSampleTime = (Float64)timestamp.sample_frame;
    *outHostTime = timestamp.host_ticks;
    *outSeed = timestamp.seed;
    return noErr;
  }
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
  if (OSVAIsVisibleDevice(deviceObjectID)) {
    memset(ioMainBuffer, 0, byteCount);
  }

  uint64_t startFrame = 0;
  const AudioTimeStamp *cycleTimestamp = OSVAIsVisibleDevice(deviceObjectID)
                                             ? &ioCycleInfo->mInputTime
                                             : &ioCycleInfo->mOutputTime;
  if (!OSVAGetIntegralCycleFrame(cycleTimestamp, &startFrame)) {
    atomic_fetch_add_explicit(&gInvalidCycleTimestampCount, 1,
                              memory_order_relaxed);
    return noErr;
  }

  OSVAClientLease lease;
  if (!OSVACopyActiveLease(deviceObjectID, clientID, &lease)) {
    /* A sibling StartIO/StopIO may temporarily fence every lease snapshot. */
    return noErr;
  }

#if defined(OSVA_DRIVER_TESTING)
  uint64_t testingFenceSequence = 0;
  bool testingFenceActive = atomic_exchange_explicit(
      &gFenceNextIOForTesting, false, memory_order_acq_rel);
  if (testingFenceActive &&
      !OSVABeginLifecycleFenceForTesting(&testingFenceSequence)) {
    return kAudioHardwareIllegalOperationError;
  }
#endif

  OSVAStatus status;
  if (OSVAIsVisibleDevice(deviceObjectID)) {
    OSVAReadResult result;
    status = OSVACoreReadFrames(&gCore, lease, startFrame,
                                (Float32 *)ioMainBuffer, frameCount, &result);
  } else {
    OSVAWriteResult result;
    status =
        OSVACoreWriteFrames(&gCore, lease, startFrame,
                            (const Float32 *)ioMainBuffer, frameCount, &result);
  }

#if defined(OSVA_DRIVER_TESTING)
  if (testingFenceActive) {
    OSVAEndLifecycleFenceForTesting(testingFenceSequence);
  }
#endif
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
  gCoreInitialized = false;
  gHost = NULL;
  atomic_store_explicit(&gReferenceCount, 1, memory_order_relaxed);
  atomic_store_explicit(&gInvalidCycleTimestampCount, 0, memory_order_relaxed);
  atomic_store_explicit(&gFenceNextIOForTesting, false, memory_order_relaxed);
  atomic_store_explicit(&gFenceZeroTimeStampCallCountForTesting, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.sequence, 0, memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.sample_frame, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.host_ticks, 0,
                        memory_order_relaxed);
  atomic_store_explicit(&gZeroTimestampCache.seed, 0, memory_order_relaxed);
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
  memset(client, 0, sizeof(*client));
  client->registered = true;
  client->device_object_id = deviceObjectID;
  client->client_id = clientInfo->mClientID;
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
  OSVADriverClient *client =
      OSVAFindDriverClient(deviceObjectID, clientInfo->mClientID);
  if (client == NULL || client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  memset(client, 0, sizeof(*client));
  pthread_mutex_unlock(&gStateMutex);
  return noErr;
}

static OSStatus OSVAStartIO(AudioServerPlugInDriverRef driver,
                            AudioObjectID deviceObjectID, UInt32 clientID) {
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  pthread_mutex_lock(&gStateMutex);
  OSVADriverClient *client = OSVAFindDriverClient(deviceObjectID, clientID);
  if (!gCoreInitialized || client == NULL || client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  bool notify = OSVAStartedClientCount(deviceObjectID) == 0;
  OSVAStatus status = OSVACoreStartClient(
      &gCore, OSVAEndpointForDevice(deviceObjectID),
      OSVACoreClientID(deviceObjectID, clientID), &client->lease);
  if (status == OSVA_STATUS_OK) {
    client->started = true;
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
  OSVADriverClient *client = OSVAFindDriverClient(deviceObjectID, clientID);
  if (!gCoreInitialized || client == NULL || !client->started) {
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareIllegalOperationError;
  }
  bool notify = OSVAStartedClientCount(deviceObjectID) == 1;
  OSVAStatus status = OSVACoreStopClient(&gCore, client->lease);
  if (status == OSVA_STATUS_OK) {
    memset(&client->lease, 0, sizeof(client->lease));
    client->started = false;
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
  (void)clientID;
  (void)operationID;
  (void)ioBufferFrameSize;
  if (!OSVAIsValidDriver(driver) || !OSVAIsDevice(deviceObjectID)) {
    return kAudioHardwareBadObjectError;
  }
  return ioCycleInfo != NULL ? noErr : kAudioHardwareIllegalOperationError;
}
