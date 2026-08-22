#include "OpensteamerVirtualMicrophoneDriver.h"

#include <CoreAudio/AudioHardware.h>

#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <math.h>
#include <pthread.h>
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
                                kAudioServerPlugInIOOperationCycle, 0, &cycle),
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
  CHECK_STATUS((*driver)->StopIO(driver, kOSVAObjectIDHiddenWriterDevice,
                                 writer.mClientID),
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

enum {
  kWrapperLifecycleStressIterations = 2000,
  kWrapperCallbackStressIterations = 8000,
  kWrapperCallbackStressFrameCount = 32,
};

typedef struct WrapperLifecycleStressContext {
  AudioServerPlugInDriverRef driver;
  UInt32 readerClientID;
  UInt32 writerClientID;
  UInt64 expectedSeed;
  _Atomic bool start;
  _Atomic unsigned failureCount;
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
  for (unsigned iteration = 0; iteration < kWrapperCallbackStressIterations;
       ++iteration) {
    Float64 sample = -1.0;
    UInt64 host = 0;
    UInt64 seed = 0;
    OSStatus status = (*context->driver)
                          ->GetZeroTimeStamp(
                              context->driver,
                              kOSVAObjectIDVisibleInputDevice,
                              context->readerClientID, &sample, &host, &seed);
    if (status != noErr || seed != context->expectedSeed || sample < 0.0 ||
        fmod(sample, (Float64)kOSVAZeroTimeStampPeriodFrames) != 0.0 ||
        host == 0 || sample < previousSample || host < previousHost) {
      WrapperStressRecordFailure(context);
      return NULL;
    }
    previousSample = sample;
    previousHost = host;
  }
  return NULL;
}

static bool TestConcurrentSiblingLifecycleNeverEscapesCallbacks(void) {
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

int main(void) {
  const struct {
    const char *name;
    bool (*run)(void);
  } tests[] = {
      {"factory and COM interface", TestFactoryAndCOMInterface},
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
      {"shared timeline both start orders and restart seed",
       TestSharedTimelineBothStartOrdersAndRestartSeed},
      {"client lifecycle and running notifications",
       TestClientLifecycleAndRunningNotifications},
      {"production I/O transfer and stale silence",
       TestProductionIOTransferAndStaleSilence},
      {"HAL-style future output feeds later input cycle",
       TestHALStyleFutureOutputFeedsLaterInputCycle},
      {"lifecycle fence fails closed and recovers",
       TestLifecycleFenceFailsClosedAndRecovers},
      {"zero timestamp lifecycle fence is hidden",
       TestZeroTimeStampLifecycleFenceIsHidden},
      {"concurrent sibling lifecycle never escapes callbacks",
       TestConcurrentSiblingLifecycleNeverEscapesCallbacks},
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
