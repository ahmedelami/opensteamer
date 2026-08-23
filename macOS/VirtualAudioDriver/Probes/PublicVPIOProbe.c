#include "PublicVPIOProbeCore.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
  kMaximumCallbackFrames = 4096,
  kSignalDurationSeconds = 6,
  kSignalFrameCount =
      kOSVAPublicVPIOExpectedSampleRate * kSignalDurationSeconds,
  kTargetCaptureFrames = kOSVAPublicVPIOExpectedSampleRate * 3,
};

static const OSStatus kProbeInternalError = (OSStatus)-70000;
static const uint64_t kCallbackStallNanoseconds = UINT64_C(500000000);
static const uint64_t kInternalRunDeadlineNanoseconds = UINT64_C(8000000000);
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2,
               "probe RT gates require lock-free atomic bools");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "probe RT counters require lock-free 64-bit atomics");
static volatile sig_atomic_t gCancellationRequested = 0;

static void HandleCancellationSignal(int signalNumber) {
  (void)signalNumber;
  gCancellationRequested = 1;
}

static bool CancellationRequested(void) {
  return gCancellationRequested != 0;
}

typedef struct TimestampTracker {
  bool has_previous;
  Float64 previous_sample_time;
  UInt64 previous_host_time;
  UInt32 previous_frame_count;
} TimestampTracker;

typedef struct ProbeContext {
  OSVAPublicVPIOEvidence evidence;

  AudioObjectPropertyAddress input_default_address;
  AudioObjectPropertyAddress output_default_address;
  AudioObjectPropertyAddress system_output_default_address;
  bool input_listener_registered;
  bool output_listener_registered;
  bool system_output_listener_registered;

  _Atomic uint64_t input_listener_sequence;
  _Atomic uint64_t output_listener_sequence;
  _Atomic uint64_t system_output_listener_sequence;
  _Atomic bool io_gate_open;
  _Atomic bool signal_enabled;

  AudioDeviceID visible_device;
  AudioDeviceID hidden_device;
  AudioDeviceID original_input_device;
  AudioDeviceID original_output_device;
  AudioDeviceID original_system_output_device;
  char original_input_uid[256];
  char original_output_uid[256];
  char original_system_output_uid[256];
  bool selection_write_succeeded;

  AudioDeviceIOProcID writer_io_proc;
  bool writer_io_proc_created;
  bool writer_started;
  AudioUnit vpio;
  bool vpio_created;
  bool vpio_initialized;
  bool vpio_started;

  _Atomic uint64_t writer_callbacks_in_flight;
  _Atomic uint64_t microphone_callbacks_in_flight;
  _Atomic uint64_t output_callbacks_in_flight;
  _Atomic uint64_t writer_callback_count;
  _Atomic uint64_t microphone_callback_count;
  _Atomic uint64_t output_callback_count;
  _Atomic uint64_t output_silence_frame_count;
  _Atomic uint64_t initial_silence_frames;
  _Atomic uint64_t writer_valid_timestamp_count;
  _Atomic uint64_t microphone_valid_timestamp_count;
  _Atomic uint64_t frozen_timestamp_count;
  _Atomic uint64_t gapped_timestamp_count;
  _Atomic uint64_t oversized_callback_count;
  _Atomic uint64_t callback_stall_count;
  _Atomic uint64_t render_error_count;
  _Atomic uint64_t known_vpio_error_count;

  TimestampTracker writer_timestamp;
  TimestampTracker microphone_timestamp;
  float *signal;
  size_t signal_frame_count;
  _Atomic uint64_t signal_cursor;
  float *capture;
  size_t capture_capacity;
  _Atomic uint64_t capture_cursor;
  float microphone_scratch[kMaximumCallbackFrames];
} ProbeContext;

static bool InputDeviceMatchesAdmissibleUID(AudioDeviceID deviceID,
                                            const char *expectedUID);

static AudioObjectPropertyAddress PropertyAddress(
    AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address = {
      .mSelector = selector,
      .mScope = scope,
      .mElement = kAudioObjectPropertyElementMain,
  };
  return address;
}

static uint64_t MonotonicNanoseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC_RAW, &now) != 0) {
    return 0;
  }
  return ((uint64_t)now.tv_sec * UINT64_C(1000000000)) +
         (uint64_t)now.tv_nsec;
}

static void SleepMilliseconds(long milliseconds) {
  struct timespec delay = {
      .tv_sec = milliseconds / 1000,
      .tv_nsec = (milliseconds % 1000) * 1000000,
  };
  while (nanosleep(&delay, &delay) != 0) {
  }
}

static OSStatus ReadProperty(AudioObjectID objectID,
                             AudioObjectPropertySelector selector,
                             AudioObjectPropertyScope scope, void *data,
                             UInt32 expectedSize) {
  AudioObjectPropertyAddress address = PropertyAddress(selector, scope);
  UInt32 size = expectedSize;
  const OSStatus status = AudioObjectGetPropertyData(
      objectID, &address, 0, NULL, &size, data);
  if (status != noErr) {
    return status;
  }
  return size == expectedSize ? noErr : kAudio_ParamError;
}

static OSStatus ReadDefaultDevice(AudioObjectPropertySelector selector,
                                  AudioDeviceID *deviceID) {
  return ReadProperty(kAudioObjectSystemObject, selector,
                      kAudioObjectPropertyScopeGlobal, deviceID,
                      (UInt32)sizeof(*deviceID));
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
  const AudioObjectPropertyAddress address =
      PropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice,
                      kAudioObjectPropertyScopeGlobal);
  UInt32 dataSize = (UInt32)sizeof(*deviceID);
  const OSStatus status = AudioObjectGetPropertyData(
      kAudioObjectSystemObject, &address, (UInt32)sizeof(qualifier), &qualifier,
      &dataSize, deviceID);
  CFRelease(qualifier);
  if (status != noErr) {
    return status;
  }
  return dataSize == sizeof(*deviceID) ? noErr : kAudio_ParamError;
}

static OSStatus WriteDefaultInputDevice(AudioDeviceID deviceID) {
  AudioObjectPropertyAddress address =
      PropertyAddress(kAudioHardwarePropertyDefaultInputDevice,
                      kAudioObjectPropertyScopeGlobal);
  const UInt32 size = (UInt32)sizeof(deviceID);
  return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                    size, &deviceID);
}

static OSStatus CopyStringProperty(AudioObjectID objectID,
                                   AudioObjectPropertySelector selector,
                                   char *destination,
                                   size_t destinationCapacity) {
  if (destination == NULL || destinationCapacity == 0) {
    return kAudio_ParamError;
  }
  destination[0] = '\0';
  CFStringRef value = NULL;
  const OSStatus status =
      ReadProperty(objectID, selector, kAudioObjectPropertyScopeGlobal, &value,
                   (UInt32)sizeof(value));
  if (status != noErr) {
    return status;
  }
  if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
    if (value != NULL) {
      CFRelease(value);
    }
    return kAudio_ParamError;
  }
  const Boolean copied = CFStringGetCString(
      value, destination, (CFIndex)destinationCapacity, kCFStringEncodingUTF8);
  CFRelease(value);
  return copied ? noErr : kAudio_ParamError;
}

static OSStatus ChannelCount(AudioDeviceID deviceID,
                             AudioObjectPropertyScope scope,
                             UInt32 *channelCount) {
  if (channelCount == NULL) {
    return kAudio_ParamError;
  }
  *channelCount = 0;
  AudioObjectPropertyAddress address =
      PropertyAddress(kAudioDevicePropertyStreamConfiguration, scope);
  UInt32 size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL,
                                                   &size);
  const UInt32 headerSize = (UInt32)offsetof(AudioBufferList, mBuffers);
  if (status != noErr || size < headerSize) {
    return status != noErr ? status : kAudio_ParamError;
  }
  AudioBufferList *list = (AudioBufferList *)calloc(1, size);
  if (list == NULL) {
    return kAudio_MemFullError;
  }
  status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, list);
  if (status == noErr) {
    if (size < headerSize) {
      free(list);
      return kAudio_ParamError;
    }
    const size_t maximumBufferCount =
        ((size_t)size - (size_t)headerSize) / sizeof(AudioBuffer);
    if ((size_t)list->mNumberBuffers > maximumBufferCount) {
      free(list);
      return kAudio_ParamError;
    }
    uint64_t sum = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
      sum += list->mBuffers[index].mNumberChannels;
    }
    if (sum > UINT32_MAX) {
      status = kAudio_ParamError;
    } else {
      *channelCount = (UInt32)sum;
    }
  }
  free(list);
  return status;
}

static bool ExactEndpointMonoFloatFormat(
    const AudioStreamBasicDescription *format) {
  if (format == NULL) {
    return false;
  }
  const AudioFormatFlags expectedFlags = kAudioFormatFlagsNativeFloatPacked;
  return fabs(format->mSampleRate - 48000.0) <= 0.0001 &&
         format->mFormatID == kAudioFormatLinearPCM &&
         format->mFormatFlags == expectedFlags &&
         format->mBytesPerPacket == sizeof(Float32) &&
         format->mFramesPerPacket == 1 &&
         format->mBytesPerFrame == sizeof(Float32) &&
         format->mChannelsPerFrame == 1 &&
         format->mBitsPerChannel == 32 && format->mReserved == 0;
}

static bool ExactClientMonoFloatFormat(
    const AudioStreamBasicDescription *format) {
  if (format == NULL) {
    return false;
  }
  const AudioFormatFlags expectedFlags =
      kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
  return fabs(format->mSampleRate - 48000.0) <= 0.0001 &&
         format->mFormatID == kAudioFormatLinearPCM &&
         format->mFormatFlags == expectedFlags &&
         format->mBytesPerPacket == sizeof(Float32) &&
         format->mFramesPerPacket == 1 &&
         format->mBytesPerFrame == sizeof(Float32) &&
         format->mChannelsPerFrame == 1 &&
         format->mBitsPerChannel == 32 && format->mReserved == 0;
}

static bool ExactClientStereoFloatFormat(
    const AudioStreamBasicDescription *format) {
  if (format == NULL) {
    return false;
  }
  const AudioFormatFlags expectedFlags =
      kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
  return fabs(format->mSampleRate - 48000.0) <= 0.0001 &&
         format->mFormatID == kAudioFormatLinearPCM &&
         format->mFormatFlags == expectedFlags &&
         format->mBytesPerPacket == sizeof(Float32) &&
         format->mFramesPerPacket == 1 &&
         format->mBytesPerFrame == sizeof(Float32) &&
         format->mChannelsPerFrame == 2 &&
         format->mBitsPerChannel == 32 && format->mReserved == 0;
}

static AudioStreamBasicDescription MonoClientFloatFormat(void) {
  AudioStreamBasicDescription format;
  memset(&format, 0, sizeof(format));
  format.mSampleRate = 48000.0;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags =
      kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
  format.mBytesPerPacket = (UInt32)sizeof(Float32);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = (UInt32)sizeof(Float32);
  format.mChannelsPerFrame = 1;
  format.mBitsPerChannel = 32;
  return format;
}

static AudioStreamBasicDescription StereoClientFloatFormat(void) {
  AudioStreamBasicDescription format = MonoClientFloatFormat();
  format.mChannelsPerFrame = 2;
  return format;
}

static OSStatus ReadSingleDeviceStreamFormats(
    AudioDeviceID deviceID, AudioObjectPropertyScope scope,
    AudioStreamBasicDescription *virtualFormat,
    AudioStreamBasicDescription *physicalFormat) {
  if (virtualFormat == NULL || physicalFormat == NULL) {
    return kAudio_ParamError;
  }
  AudioObjectPropertyAddress streamsAddress =
      PropertyAddress(kAudioDevicePropertyStreams, scope);
  UInt32 streamsSize = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(
      deviceID, &streamsAddress, 0, NULL, &streamsSize);
  if (status != noErr || streamsSize != sizeof(AudioStreamID)) {
    return status != noErr ? status : kAudio_ParamError;
  }
  AudioStreamID streamID = kAudioObjectUnknown;
  status = AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, NULL,
                                      &streamsSize, &streamID);
  if (status != noErr || streamsSize != sizeof(streamID) ||
      streamID == kAudioObjectUnknown) {
    return status != noErr ? status : kAudio_ParamError;
  }
  status = ReadProperty(streamID, kAudioStreamPropertyVirtualFormat,
                        kAudioObjectPropertyScopeGlobal, virtualFormat,
                        (UInt32)sizeof(*virtualFormat));
  if (status != noErr) {
    return status;
  }
  return ReadProperty(streamID, kAudioStreamPropertyPhysicalFormat,
                      kAudioObjectPropertyScopeGlobal, physicalFormat,
                      (UInt32)sizeof(*physicalFormat));
}

static bool DeviceIsRealAliveOutput(AudioDeviceID deviceID,
                                    UInt32 *channelCount) {
  UInt32 alive = 0;
  UInt32 transport = 0;
  UInt32 channels = 0;
  if (ReadProperty(deviceID, kAudioDevicePropertyDeviceIsAlive,
                   kAudioObjectPropertyScopeGlobal, &alive,
                   (UInt32)sizeof(alive)) != noErr ||
      ReadProperty(deviceID, kAudioDevicePropertyTransportType,
                   kAudioObjectPropertyScopeGlobal, &transport,
                   (UInt32)sizeof(transport)) != noErr ||
      ChannelCount(deviceID, kAudioDevicePropertyScopeOutput, &channels) !=
          noErr) {
    return false;
  }
  if (channelCount != NULL) {
    *channelCount = channels;
  }
  return deviceID != kAudioObjectUnknown && alive != 0 && channels > 0 &&
         transport != kAudioDeviceTransportTypeVirtual &&
         transport != kAudioDeviceTransportTypeAggregate;
}

static OSStatus DefaultDeviceListener(
    AudioObjectID objectID, UInt32 addressCount,
    const AudioObjectPropertyAddress addresses[], void *clientData) {
  (void)objectID;
  ProbeContext *context = (ProbeContext *)clientData;
  if (context == NULL || addresses == NULL) {
    return noErr;
  }
  for (UInt32 index = 0; index < addressCount; ++index) {
    switch (addresses[index].mSelector) {
    case kAudioHardwarePropertyDefaultInputDevice:
      atomic_fetch_add_explicit(&context->input_listener_sequence, 1,
                                memory_order_acq_rel);
      break;
    case kAudioHardwarePropertyDefaultOutputDevice:
      atomic_fetch_add_explicit(&context->output_listener_sequence, 1,
                                memory_order_acq_rel);
      break;
    case kAudioHardwarePropertyDefaultSystemOutputDevice:
      atomic_fetch_add_explicit(&context->system_output_listener_sequence, 1,
                                memory_order_acq_rel);
      break;
    default:
      break;
    }
  }
  atomic_store_explicit(&context->io_gate_open, false, memory_order_release);
  return noErr;
}

static bool RegisterDefaultListeners(ProbeContext *context) {
  context->input_default_address =
      PropertyAddress(kAudioHardwarePropertyDefaultInputDevice,
                      kAudioObjectPropertyScopeGlobal);
  context->output_default_address =
      PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice,
                      kAudioObjectPropertyScopeGlobal);
  context->system_output_default_address =
      PropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice,
                      kAudioObjectPropertyScopeGlobal);

  OSStatus status = AudioObjectAddPropertyListener(
      kAudioObjectSystemObject, &context->input_default_address,
      DefaultDeviceListener, context);
  if (status != noErr) {
    return false;
  }
  context->input_listener_registered = true;
  status = AudioObjectAddPropertyListener(
      kAudioObjectSystemObject, &context->output_default_address,
      DefaultDeviceListener, context);
  if (status != noErr) {
    return false;
  }
  context->output_listener_registered = true;
  status = AudioObjectAddPropertyListener(
      kAudioObjectSystemObject, &context->system_output_default_address,
      DefaultDeviceListener, context);
  if (status != noErr) {
    return false;
  }
  context->system_output_listener_registered = true;
  context->evidence.listeners_registered_before_default_reads = true;
  return true;
}

static bool RemoveDefaultListeners(ProbeContext *context) {
  bool removed = true;
  if (context->input_listener_registered) {
    const OSStatus status = AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &context->input_default_address,
        DefaultDeviceListener, context);
    removed = removed && status == noErr;
    if (status == noErr) {
      context->input_listener_registered = false;
    }
  }
  if (context->output_listener_registered) {
    const OSStatus status = AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &context->output_default_address,
        DefaultDeviceListener, context);
    removed = removed && status == noErr;
    if (status == noErr) {
      context->output_listener_registered = false;
    }
  }
  if (context->system_output_listener_registered) {
    const OSStatus status = AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &context->system_output_default_address,
        DefaultDeviceListener, context);
    removed = removed && status == noErr;
    if (status == noErr) {
      context->system_output_listener_registered = false;
    }
  }
  return removed;
}

static bool ReadDefaultSnapshot(ProbeContext *context) {
  if (ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice,
                        &context->original_input_device) != noErr ||
      ReadDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice,
                        &context->original_output_device) != noErr ||
      ReadDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice,
                        &context->original_system_output_device) != noErr) {
    return false;
  }
  if (context->original_input_device == kAudioObjectUnknown ||
      context->original_output_device == kAudioObjectUnknown ||
      context->original_system_output_device == kAudioObjectUnknown ||
      CopyStringProperty(context->original_input_device,
                         kAudioDevicePropertyDeviceUID,
                         context->original_input_uid,
                         sizeof(context->original_input_uid)) != noErr ||
      CopyStringProperty(context->original_output_device,
                         kAudioDevicePropertyDeviceUID,
                         context->original_output_uid,
                         sizeof(context->original_output_uid)) != noErr ||
      CopyStringProperty(context->original_system_output_device,
                         kAudioDevicePropertyDeviceUID,
                         context->original_system_output_uid,
                         sizeof(context->original_system_output_uid)) != noErr) {
    return false;
  }
  UInt32 inputAlive = 0;
  UInt32 inputHidden = 0;
  const bool inputPropertiesValid =
      ReadProperty(context->original_input_device,
                   kAudioDevicePropertyDeviceIsAlive,
                   kAudioObjectPropertyScopeGlobal, &inputAlive,
                   (UInt32)sizeof(inputAlive)) == noErr &&
      ReadProperty(context->original_input_device,
                   kAudioDevicePropertyIsHidden,
                   kAudioObjectPropertyScopeGlobal, &inputHidden,
                   (UInt32)sizeof(inputHidden)) == noErr;
  context->evidence.original_input_uid_hash =
      OSVAPublicVPIOHashString(context->original_input_uid);
  context->evidence.original_input_is_admissible_for_restoration =
      inputPropertiesValid && inputAlive != 0 && inputHidden == 0 &&
      !OSVAPublicVPIOIsForbiddenRestorationInputUID(
          context->original_input_uid);
  return context->evidence.original_input_is_admissible_for_restoration &&
         atomic_load_explicit(&context->input_listener_sequence,
                              memory_order_acquire) == 0 &&
         atomic_load_explicit(&context->output_listener_sequence,
                              memory_order_acquire) == 0 &&
         atomic_load_explicit(&context->system_output_listener_sequence,
                              memory_order_acquire) == 0;
}

static bool ResolveExactEndpoints(ProbeContext *context) {
  return TranslateExactDeviceUID(OSVA_PUBLIC_VPIO_VISIBLE_UID,
                                 &context->visible_device) == noErr &&
         TranslateExactDeviceUID(OSVA_PUBLIC_VPIO_HIDDEN_UID,
                                 &context->hidden_device) == noErr &&
         context->visible_device != kAudioObjectUnknown &&
         context->hidden_device != kAudioObjectUnknown &&
         context->visible_device != context->hidden_device;
}

static bool EndpointTranslationsStillMatch(const ProbeContext *context) {
  AudioDeviceID visible = kAudioObjectUnknown;
  AudioDeviceID hidden = kAudioObjectUnknown;
  return TranslateExactDeviceUID(OSVA_PUBLIC_VPIO_VISIBLE_UID, &visible) ==
             noErr &&
         TranslateExactDeviceUID(OSVA_PUBLIC_VPIO_HIDDEN_UID, &hidden) ==
             noErr &&
         visible == context->visible_device && hidden == context->hidden_device &&
         visible != hidden;
}

static bool PopulateOneEndpoint(ProbeContext *context, AudioDeviceID deviceID,
                                bool isVisible) {
  char uid[256];
  char modelUID[256];
  UInt32 alive = 0;
  UInt32 hidden = 0;
  UInt32 clockDomain = 0;
  Float64 nominalRate = 0.0;
  UInt32 inputChannels = 0;
  UInt32 outputChannels = 0;
  AudioStreamBasicDescription virtualFormat;
  AudioStreamBasicDescription physicalFormat;
  memset(&virtualFormat, 0, sizeof(virtualFormat));
  memset(&physicalFormat, 0, sizeof(physicalFormat));

  OSStatus formatStatus = noErr;
  const bool propertiesRead =
      CopyStringProperty(deviceID, kAudioDevicePropertyDeviceUID, uid,
                         sizeof(uid)) == noErr &&
      CopyStringProperty(deviceID, kAudioDevicePropertyModelUID, modelUID,
                         sizeof(modelUID)) == noErr &&
      ReadProperty(deviceID, kAudioDevicePropertyDeviceIsAlive,
                   kAudioObjectPropertyScopeGlobal, &alive,
                   (UInt32)sizeof(alive)) == noErr &&
      ReadProperty(deviceID, kAudioDevicePropertyIsHidden,
                   kAudioObjectPropertyScopeGlobal, &hidden,
                   (UInt32)sizeof(hidden)) == noErr &&
      ReadProperty(deviceID, kAudioDevicePropertyClockDomain,
                   kAudioObjectPropertyScopeGlobal, &clockDomain,
                   (UInt32)sizeof(clockDomain)) == noErr &&
      ReadProperty(deviceID, kAudioDevicePropertyNominalSampleRate,
                   kAudioObjectPropertyScopeGlobal, &nominalRate,
                   (UInt32)sizeof(nominalRate)) == noErr &&
      ChannelCount(deviceID, kAudioDevicePropertyScopeInput, &inputChannels) ==
          noErr &&
      ChannelCount(deviceID, kAudioDevicePropertyScopeOutput,
                   &outputChannels) == noErr;
  formatStatus = ReadSingleDeviceStreamFormats(
      deviceID,
      isVisible ? kAudioDevicePropertyScopeInput
                : kAudioDevicePropertyScopeOutput,
      &virtualFormat, &physicalFormat);

  if (isVisible) {
    context->evidence.visible_uid_hash = OSVAPublicVPIOHashString(uid);
    context->evidence.visible_model_uid_hash =
        OSVAPublicVPIOHashString(modelUID);
    context->evidence.visible_is_alive = alive != 0;
    context->evidence.visible_is_hidden = hidden != 0;
    context->evidence.visible_clock_domain = clockDomain;
    context->evidence.visible_nominal_sample_rate = nominalRate;
    context->evidence.visible_input_channels = inputChannels;
    context->evidence.visible_output_channels = outputChannels;
    context->evidence.visible_format_status = formatStatus;
    context->evidence.visible_stream_format_exact =
        formatStatus == noErr &&
        ExactEndpointMonoFloatFormat(&virtualFormat) &&
        ExactEndpointMonoFloatFormat(&physicalFormat);
  } else {
    context->evidence.hidden_uid_hash = OSVAPublicVPIOHashString(uid);
    context->evidence.hidden_model_uid_hash =
        OSVAPublicVPIOHashString(modelUID);
    context->evidence.hidden_is_alive = alive != 0;
    context->evidence.hidden_is_hidden = hidden != 0;
    context->evidence.hidden_clock_domain = clockDomain;
    context->evidence.hidden_nominal_sample_rate = nominalRate;
    context->evidence.hidden_input_channels = inputChannels;
    context->evidence.hidden_output_channels = outputChannels;
    context->evidence.hidden_format_status = formatStatus;
    context->evidence.hidden_stream_format_exact =
        formatStatus == noErr &&
        ExactEndpointMonoFloatFormat(&virtualFormat) &&
        ExactEndpointMonoFloatFormat(&physicalFormat);
  }
  return propertiesRead && formatStatus == noErr;
}

static bool PopulateEndpointEvidence(ProbeContext *context) {
  context->evidence.devices_are_distinct =
      context->visible_device != context->hidden_device;
  const bool visible =
      PopulateOneEndpoint(context, context->visible_device, true);
  const bool hidden =
      PopulateOneEndpoint(context, context->hidden_device, false);
  return visible && hidden;
}

static bool PopulateOutputEvidence(ProbeContext *context) {
  char outputUIDReadback[256];
  char systemOutputUIDReadback[256];
  if (CopyStringProperty(context->original_output_device,
                         kAudioDevicePropertyDeviceUID, outputUIDReadback,
                         sizeof(outputUIDReadback)) != noErr ||
      CopyStringProperty(context->original_system_output_device,
                         kAudioDevicePropertyDeviceUID,
                         systemOutputUIDReadback,
                         sizeof(systemOutputUIDReadback)) != noErr ||
      strcmp(outputUIDReadback, context->original_output_uid) != 0 ||
      strcmp(systemOutputUIDReadback,
             context->original_system_output_uid) != 0) {
    return false;
  }
  context->evidence.default_output_uid_hash =
      OSVAPublicVPIOHashString(context->original_output_uid);
  context->evidence.default_system_output_uid_hash =
      OSVAPublicVPIOHashString(context->original_system_output_uid);
  context->evidence.default_output_is_forbidden_virtual =
      OSVAPublicVPIOIsForbiddenOutputUID(context->original_output_uid);
  context->evidence.default_system_output_is_forbidden_virtual =
      OSVAPublicVPIOIsForbiddenOutputUID(
          context->original_system_output_uid);
  context->evidence.default_output_is_real_and_alive = DeviceIsRealAliveOutput(
      context->original_output_device,
      &context->evidence.default_output_channels);
  context->evidence.default_system_output_is_real_and_alive =
      DeviceIsRealAliveOutput(
          context->original_system_output_device,
          &context->evidence.default_system_output_channels);
  return !context->evidence.default_output_is_forbidden_virtual &&
         !context->evidence.default_system_output_is_forbidden_virtual &&
         context->evidence.default_output_is_real_and_alive &&
         context->evidence.default_system_output_is_real_and_alive;
}

static bool OutputDefaultsStillMatchAndAreSafe(const ProbeContext *context) {
  const uint64_t outputSequenceBefore = atomic_load_explicit(
      &context->output_listener_sequence, memory_order_acquire);
  const uint64_t systemSequenceBefore = atomic_load_explicit(
      &context->system_output_listener_sequence, memory_order_acquire);
  AudioDeviceID output = kAudioObjectUnknown;
  AudioDeviceID systemOutput = kAudioObjectUnknown;
  char outputUID[256];
  char systemOutputUID[256];
  UInt32 outputChannels = 0;
  UInt32 systemOutputChannels = 0;
  const bool readsSucceeded =
      ReadDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, &output) ==
          noErr &&
      ReadDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice,
                        &systemOutput) == noErr &&
      output == context->original_output_device &&
      systemOutput == context->original_system_output_device &&
      CopyStringProperty(output, kAudioDevicePropertyDeviceUID, outputUID,
                         sizeof(outputUID)) == noErr &&
      CopyStringProperty(systemOutput, kAudioDevicePropertyDeviceUID,
                         systemOutputUID, sizeof(systemOutputUID)) == noErr &&
      strcmp(outputUID, context->original_output_uid) == 0 &&
      strcmp(systemOutputUID, context->original_system_output_uid) == 0 &&
      !OSVAPublicVPIOIsForbiddenOutputUID(outputUID) &&
      !OSVAPublicVPIOIsForbiddenOutputUID(systemOutputUID) &&
      DeviceIsRealAliveOutput(output, &outputChannels) &&
      DeviceIsRealAliveOutput(systemOutput, &systemOutputChannels) &&
      outputChannels > 0 && systemOutputChannels > 0;
  const uint64_t outputSequenceAfter = atomic_load_explicit(
      &context->output_listener_sequence, memory_order_acquire);
  const uint64_t systemSequenceAfter = atomic_load_explicit(
      &context->system_output_listener_sequence, memory_order_acquire);
  return readsSucceeded && outputSequenceBefore == 0 &&
         systemSequenceBefore == 0 &&
         outputSequenceBefore == outputSequenceAfter &&
         systemSequenceBefore == systemSequenceAfter;
}

static bool InputDefaultStillVisibleAndStable(const ProbeContext *context) {
  const uint64_t sequenceBefore = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  AudioDeviceID input = kAudioObjectUnknown;
  const bool readSucceeded =
      ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &input) ==
      noErr;
  const uint64_t sequenceAfter = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  return readSucceeded && input == context->visible_device &&
         sequenceBefore == context->evidence.input_listener_sequence_at_commit &&
         sequenceBefore == sequenceAfter;
}

static void RecordTimestamp(ProbeContext *context, TimestampTracker *tracker,
                            const AudioTimeStamp *timestamp, UInt32 frameCount,
                            _Atomic uint64_t *validCount) {
  if (timestamp == NULL ||
      (timestamp->mFlags & kAudioTimeStampSampleTimeValid) == 0 ||
      (timestamp->mFlags & kAudioTimeStampHostTimeValid) == 0 ||
      !isfinite(timestamp->mSampleTime)) {
    return;
  }
  atomic_fetch_add_explicit(validCount, 1, memory_order_relaxed);
  if (tracker->has_previous) {
    const Float64 delta =
        timestamp->mSampleTime - tracker->previous_sample_time;
    if (delta <= 0.0 || timestamp->mHostTime <= tracker->previous_host_time) {
      atomic_fetch_add_explicit(&context->frozen_timestamp_count, 1,
                                memory_order_relaxed);
    } else {
      const Float64 expected = (Float64)tracker->previous_frame_count;
      if (fabs(delta - expected) > 8.0) {
        atomic_fetch_add_explicit(&context->gapped_timestamp_count, 1,
                                  memory_order_relaxed);
      }
    }
  }
  tracker->has_previous = true;
  tracker->previous_sample_time = timestamp->mSampleTime;
  tracker->previous_host_time = timestamp->mHostTime;
  tracker->previous_frame_count = frameCount;
}

static OSStatus HiddenWriterIOProc(
    AudioObjectID deviceID, const AudioTimeStamp *now,
    const AudioBufferList *inputData, const AudioTimeStamp *inputTime,
    AudioBufferList *outputData, const AudioTimeStamp *outputTime,
    void *clientData) {
  (void)deviceID;
  (void)now;
  (void)inputData;
  (void)inputTime;
  ProbeContext *context = (ProbeContext *)clientData;
  if (context == NULL || outputData == NULL) {
    return noErr;
  }
  atomic_fetch_add_explicit(&context->writer_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  atomic_fetch_add_explicit(&context->writer_callback_count, 1,
                            memory_order_relaxed);

  UInt32 frameCount = 0;
  if (outputData->mNumberBuffers > 0) {
    frameCount = outputData->mBuffers[0].mDataByteSize / (UInt32)sizeof(Float32);
  }
  RecordTimestamp(context, &context->writer_timestamp, outputTime, frameCount,
                  &context->writer_valid_timestamp_count);

  const bool gateOpen =
      atomic_load_explicit(&context->io_gate_open, memory_order_acquire);
  const bool signalEnabled =
      atomic_load_explicit(&context->signal_enabled, memory_order_acquire);
  uint64_t signalStart = 0;
  if (gateOpen && signalEnabled) {
    signalStart = atomic_fetch_add_explicit(&context->signal_cursor, frameCount,
                                            memory_order_relaxed);
  } else {
    atomic_fetch_add_explicit(&context->initial_silence_frames, frameCount,
                              memory_order_relaxed);
  }

  for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers;
       ++bufferIndex) {
    AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
    if (buffer->mData == NULL) {
      continue;
    }
    const size_t availableFrames =
        (size_t)buffer->mDataByteSize / sizeof(Float32);
    const size_t boundedFrames =
        availableFrames < kMaximumCallbackFrames ? availableFrames
                                                 : kMaximumCallbackFrames;
    if (availableFrames > kMaximumCallbackFrames) {
      atomic_fetch_add_explicit(&context->oversized_callback_count, 1,
                                memory_order_relaxed);
    }
    Float32 *samples = (Float32 *)buffer->mData;
    memset(samples, 0, buffer->mDataByteSize);
    if (gateOpen && signalEnabled && context->signal_frame_count > 0) {
      for (size_t index = 0; index < boundedFrames; ++index) {
        const uint64_t signalIndex = signalStart + (uint64_t)index;
        samples[index] =
            context->signal[signalIndex % context->signal_frame_count];
      }
    }
  }

  atomic_fetch_sub_explicit(&context->writer_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  return noErr;
}

static OSStatus MicrophoneInputCallback(
    void *clientData, AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp, UInt32 busNumber, UInt32 frameCount,
    AudioBufferList *data) {
  (void)data;
  ProbeContext *context = (ProbeContext *)clientData;
  if (context == NULL) {
    return noErr;
  }
  atomic_fetch_add_explicit(&context->microphone_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  atomic_fetch_add_explicit(&context->microphone_callback_count, 1,
                            memory_order_relaxed);

  if (!atomic_load_explicit(&context->io_gate_open, memory_order_acquire)) {
    atomic_fetch_sub_explicit(&context->microphone_callbacks_in_flight, 1,
                              memory_order_acq_rel);
    return noErr;
  }
  if (frameCount > kMaximumCallbackFrames) {
    atomic_fetch_add_explicit(&context->oversized_callback_count, 1,
                              memory_order_relaxed);
    atomic_fetch_sub_explicit(&context->microphone_callbacks_in_flight, 1,
                              memory_order_acq_rel);
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  AudioBufferList renderData;
  memset(&renderData, 0, sizeof(renderData));
  renderData.mNumberBuffers = 1;
  renderData.mBuffers[0].mNumberChannels = 1;
  renderData.mBuffers[0].mDataByteSize =
      frameCount * (UInt32)sizeof(Float32);
  renderData.mBuffers[0].mData = context->microphone_scratch;
  if (busNumber != 1) {
    atomic_fetch_add_explicit(&context->known_vpio_error_count, 1,
                              memory_order_relaxed);
    atomic_fetch_sub_explicit(&context->microphone_callbacks_in_flight, 1,
                              memory_order_acq_rel);
    return kAudioUnitErr_InvalidElement;
  }
  const OSStatus renderStatus = AudioUnitRender(
      context->vpio, actionFlags, timestamp, busNumber, frameCount, &renderData);
  if (renderStatus != noErr) {
    atomic_fetch_add_explicit(&context->render_error_count, 1,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&context->known_vpio_error_count, 1,
                              memory_order_relaxed);
    atomic_fetch_sub_explicit(&context->microphone_callbacks_in_flight, 1,
                              memory_order_acq_rel);
    return renderStatus;
  }

  RecordTimestamp(context, &context->microphone_timestamp, timestamp,
                  frameCount, &context->microphone_valid_timestamp_count);
  if (atomic_load_explicit(&context->signal_enabled, memory_order_acquire)) {
    const uint64_t cursor = atomic_load_explicit(&context->capture_cursor,
                                                 memory_order_relaxed);
    if (cursor < context->capture_capacity) {
      size_t copyCount = (size_t)frameCount;
      const size_t available = context->capture_capacity - (size_t)cursor;
      if (copyCount > available) {
        copyCount = available;
      }
      memcpy(&context->capture[cursor], context->microphone_scratch,
             copyCount * sizeof(Float32));
      atomic_store_explicit(&context->capture_cursor,
                            cursor + (uint64_t)copyCount,
                            memory_order_release);
    }
  }

  atomic_fetch_sub_explicit(&context->microphone_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  return noErr;
}

static OSStatus SilenceOutputCallback(
    void *clientData, AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp, UInt32 busNumber, UInt32 frameCount,
    AudioBufferList *data) {
  (void)timestamp;
  (void)busNumber;
  ProbeContext *context = (ProbeContext *)clientData;
  if (context == NULL || data == NULL) {
    return noErr;
  }
  atomic_fetch_add_explicit(&context->output_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  atomic_fetch_add_explicit(&context->output_callback_count, 1,
                            memory_order_relaxed);
  if (frameCount > kMaximumCallbackFrames || data->mNumberBuffers != 2) {
    atomic_fetch_add_explicit(&context->oversized_callback_count, 1,
                              memory_order_relaxed);
    atomic_fetch_sub_explicit(&context->output_callbacks_in_flight, 1,
                              memory_order_acq_rel);
    return kAudioUnitErr_TooManyFramesToProcess;
  }
  const UInt32 expectedBytes = frameCount * (UInt32)sizeof(Float32);
  for (UInt32 index = 0; index < 2; ++index) {
    if (data->mBuffers[index].mNumberChannels != 1 ||
        data->mBuffers[index].mData == NULL ||
        data->mBuffers[index].mDataByteSize != expectedBytes) {
      atomic_fetch_add_explicit(&context->oversized_callback_count, 1,
                                memory_order_relaxed);
      atomic_fetch_sub_explicit(&context->output_callbacks_in_flight, 1,
                                memory_order_acq_rel);
      return kAudioUnitErr_TooManyFramesToProcess;
    }
  }
  for (UInt32 index = 0; index < 2; ++index) {
    memset(data->mBuffers[index].mData, 0, expectedBytes);
  }
  atomic_fetch_add_explicit(&context->output_silence_frame_count, frameCount,
                            memory_order_relaxed);
  if (actionFlags != NULL) {
    *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
  }
  atomic_fetch_sub_explicit(&context->output_callbacks_in_flight, 1,
                            memory_order_acq_rel);
  return noErr;
}

static void GenerateNonceSignal(ProbeContext *context) {
  uint64_t nonce[4];
  arc4random_buf(nonce, sizeof(nonce));
  context->evidence.nonce_hash =
      OSVAPublicVPIOHashBytes(nonce, sizeof(nonce));
  uint64_t state = nonce[0] ^ nonce[1] ^ nonce[2] ^ nonce[3];
  if (state == 0) {
    state = UINT64_C(0x4f5356415650494f);
  }
  for (size_t index = 0; index < context->signal_frame_count; ++index) {
    if ((index % 3840) == 0) {
      state ^= state << 13;
      state ^= state >> 7;
      state ^= state << 17;
    }
    const double amplitude =
        0.025 + (0.025 * (double)(1 + (state & UINT64_C(3))));
    const double time = (double)index / 48000.0;
    const double voiced = (0.43 * sin(2.0 * M_PI * 367.0 * time)) +
                          (0.31 * sin(2.0 * M_PI * 733.0 * time)) +
                          (0.19 * sin(2.0 * M_PI * 1291.0 * time)) +
                          (0.11 * sin(2.0 * M_PI * 2179.0 * time));
    context->signal[index] = (Float32)(amplitude * voiced);
  }
}

static bool WaitForWriterSilence(ProbeContext *context) {
  const uint64_t deadline = MonotonicNanoseconds() + UINT64_C(2000000000);
  while (MonotonicNanoseconds() < deadline && !CancellationRequested()) {
    if (atomic_load_explicit(&context->writer_callback_count,
                             memory_order_acquire) >=
            kOSVAPublicVPIOMinimumCallbackCount &&
        atomic_load_explicit(&context->initial_silence_frames,
                             memory_order_acquire) > 0) {
      return true;
    }
    SleepMilliseconds(10);
  }
  atomic_fetch_add_explicit(&context->callback_stall_count, 1,
                            memory_order_relaxed);
  return false;
}

static bool WaitForDefaultInput(AudioDeviceID expectedDevice,
                                uint64_t previousSequence,
                                _Atomic uint64_t *sequence,
                                bool requireAdvance,
                                bool abortOnCancellation) {
  const uint64_t deadline = MonotonicNanoseconds() + UINT64_C(2000000000);
  while (MonotonicNanoseconds() < deadline &&
         (!abortOnCancellation || !CancellationRequested())) {
    AudioDeviceID current = kAudioObjectUnknown;
    const uint64_t observed =
        atomic_load_explicit(sequence, memory_order_acquire);
    if (ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &current) ==
            noErr &&
        current == expectedDevice &&
        (!requireAdvance || observed > previousSequence)) {
      return true;
    }
    SleepMilliseconds(10);
  }
  return false;
}

static bool SelectVisibleDefaultInput(ProbeContext *context) {
  context->evidence.endpoint_translation_stable_before_commit =
      EndpointTranslationsStillMatch(context);
  if (!context->evidence.endpoint_translation_stable_before_commit) {
    return false;
  }
  AudioDeviceID comparison = kAudioObjectUnknown;
  if (ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &comparison) !=
      noErr) {
    return false;
  }
  context->evidence.selection_comparison_matched =
      comparison == context->original_input_device &&
      InputDeviceMatchesAdmissibleUID(comparison,
                                      context->original_input_uid);
  if (!context->evidence.selection_comparison_matched) {
    return false;
  }

  const uint64_t before = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  context->evidence.input_listener_sequence_before_selection = before;
  if (before != 0) {
    return false;
  }
  context->evidence.default_input_was_changed =
      comparison != context->visible_device;
  if (context->evidence.default_input_was_changed) {
    if (WriteDefaultInputDevice(context->visible_device) != noErr) {
      return false;
    }
    context->selection_write_succeeded = true;
    context->evidence.selection_readback_matched = WaitForDefaultInput(
        context->visible_device, before, &context->input_listener_sequence,
        true, true);
  } else {
    context->evidence.selection_readback_matched = WaitForDefaultInput(
        context->visible_device, before, &context->input_listener_sequence,
        false, true);
  }
  if (!context->evidence.selection_readback_matched) {
    context->evidence.input_listener_sequence_at_commit = atomic_load_explicit(
        &context->input_listener_sequence, memory_order_acquire);
    return false;
  }

  const uint64_t sequenceBeforeCommit = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  AudioDeviceID committedInput = kAudioObjectUnknown;
  const bool readSucceeded =
      ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice,
                        &committedInput) == noErr;
  const uint64_t sequenceAfterCommit = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  context->evidence.selection_listener_advanced =
      context->evidence.default_input_was_changed
          ? sequenceBeforeCommit > before
          : sequenceBeforeCommit == before;
  context->evidence.selection_commit_sequence_stable =
      sequenceBeforeCommit == sequenceAfterCommit;
  context->evidence.visible_was_default_input_at_commit =
      readSucceeded && committedInput == context->visible_device;
  context->evidence.input_listener_sequence_at_commit = sequenceAfterCommit;
  if (!context->evidence.selection_listener_advanced ||
      !context->evidence.selection_commit_sequence_stable ||
      !context->evidence.visible_was_default_input_at_commit ||
      atomic_load_explicit(&context->output_listener_sequence,
                           memory_order_acquire) != 0 ||
      atomic_load_explicit(&context->system_output_listener_sequence,
                           memory_order_acquire) != 0) {
    return false;
  }
  context->evidence.endpoint_translation_stable_before_commit =
      context->evidence.endpoint_translation_stable_before_commit &&
      EndpointTranslationsStillMatch(context);
  context->evidence.output_defaults_stable_and_safe_before_gate =
      OutputDefaultsStillMatchAndAreSafe(context);
  if (!context->evidence.endpoint_translation_stable_before_commit ||
      !context->evidence.output_defaults_stable_and_safe_before_gate) {
    return false;
  }
  atomic_store_explicit(&context->io_gate_open, true, memory_order_release);
  return true;
}

static bool StartHiddenWriter(ProbeContext *context) {
  context->evidence.writer_create_status = AudioDeviceCreateIOProcID(
      context->hidden_device, HiddenWriterIOProc, context,
      &context->writer_io_proc);
  if (context->evidence.writer_create_status != noErr) {
    return false;
  }
  context->writer_io_proc_created = true;
  atomic_store_explicit(&context->signal_enabled, false, memory_order_release);
  context->evidence.writer_start_status =
      AudioDeviceStart(context->hidden_device, context->writer_io_proc);
  if (context->evidence.writer_start_status != noErr) {
    return false;
  }
  context->writer_started = true;
  context->evidence.hidden_writer_started_first = true;
  return WaitForWriterSilence(context);
}

static bool ConfigureAndStartVPIO(ProbeContext *context) {
  AudioComponentDescription description = {
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_VoiceProcessingIO,
      .componentManufacturer = kAudioUnitManufacturer_Apple,
      .componentFlags = 0,
      .componentFlagsMask = 0,
  };
  const AudioComponent component = AudioComponentFindNext(NULL, &description);
  if (component == NULL) {
    context->evidence.component_status = kProbeInternalError;
    return false;
  }
  context->evidence.component_status =
      AudioComponentInstanceNew(component, &context->vpio);
  if (context->evidence.component_status != noErr) {
    return false;
  }
  context->vpio_created = true;

  UInt32 enabled = 1;
  context->evidence.enable_input_status = AudioUnitSetProperty(
      context->vpio, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
      1, &enabled, (UInt32)sizeof(enabled));
  context->evidence.enable_output_status = AudioUnitSetProperty(
      context->vpio, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
      0, &enabled, (UInt32)sizeof(enabled));
  if (context->evidence.enable_input_status != noErr ||
      context->evidence.enable_output_status != noErr) {
    return false;
  }

  const AudioStreamBasicDescription captureFormat = MonoClientFloatFormat();
  const AudioStreamBasicDescription playoutFormat = StereoClientFloatFormat();
  context->evidence.processed_mic_format_set_status = AudioUnitSetProperty(
      context->vpio, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
      &captureFormat, (UInt32)sizeof(captureFormat));
  context->evidence.playout_format_set_status = AudioUnitSetProperty(
      context->vpio, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
      &playoutFormat, (UInt32)sizeof(playoutFormat));
  if (context->evidence.processed_mic_format_set_status != noErr ||
      context->evidence.playout_format_set_status != noErr) {
    return false;
  }

  AudioStreamBasicDescription readback;
  memset(&readback, 0, sizeof(readback));
  UInt32 readbackSize = (UInt32)sizeof(readback);
  context->evidence.processed_mic_format_read_status = AudioUnitGetProperty(
      context->vpio, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
      &readback, &readbackSize);
  context->evidence.processed_mic_sample_rate = readback.mSampleRate;
  context->evidence.processed_mic_channels = readback.mChannelsPerFrame;
  context->evidence.processed_mic_stream_format_exact =
      context->evidence.processed_mic_format_read_status == noErr &&
      readbackSize == sizeof(readback) &&
      ExactClientMonoFloatFormat(&readback);
  if (!context->evidence.processed_mic_stream_format_exact) {
    return false;
  }

  AudioStreamBasicDescription playoutReadback;
  memset(&playoutReadback, 0, sizeof(playoutReadback));
  UInt32 playoutReadbackSize = (UInt32)sizeof(playoutReadback);
  context->evidence.playout_format_read_status = AudioUnitGetProperty(
      context->vpio, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
      &playoutReadback, &playoutReadbackSize);
  context->evidence.playout_sample_rate = playoutReadback.mSampleRate;
  context->evidence.playout_channels = playoutReadback.mChannelsPerFrame;
  context->evidence.playout_stream_format_exact =
      context->evidence.playout_format_read_status == noErr &&
      playoutReadbackSize == sizeof(playoutReadback) &&
      ExactClientStereoFloatFormat(&playoutReadback);
  if (!context->evidence.playout_stream_format_exact) {
    return false;
  }

  const AURenderCallbackStruct inputCallback = {
      .inputProc = MicrophoneInputCallback,
      .inputProcRefCon = context,
  };
  context->evidence.input_callback_status = AudioUnitSetProperty(
      context->vpio, kAudioOutputUnitProperty_SetInputCallback,
      kAudioUnitScope_Global, 0, &inputCallback,
      (UInt32)sizeof(inputCallback));
  const AURenderCallbackStruct outputCallback = {
      .inputProc = SilenceOutputCallback,
      .inputProcRefCon = context,
  };
  context->evidence.output_callback_status = AudioUnitSetProperty(
      context->vpio, kAudioUnitProperty_SetRenderCallback,
      kAudioUnitScope_Input, 0, &outputCallback,
      (UInt32)sizeof(outputCallback));
  if (context->evidence.input_callback_status != noErr ||
      context->evidence.output_callback_status != noErr) {
    return false;
  }

  UInt32 bypassVoiceProcessing = 0;
  context->evidence.voice_processing_bypass_status = AudioUnitSetProperty(
      context->vpio, kAUVoiceIOProperty_BypassVoiceProcessing,
      kAudioUnitScope_Global, 0, &bypassVoiceProcessing,
      (UInt32)sizeof(bypassVoiceProcessing));
  UInt32 bypassReadback = 1;
  UInt32 bypassReadbackSize = (UInt32)sizeof(bypassReadback);
  const OSStatus bypassReadStatus = AudioUnitGetProperty(
      context->vpio, kAUVoiceIOProperty_BypassVoiceProcessing,
      kAudioUnitScope_Global, 0, &bypassReadback, &bypassReadbackSize);
  context->evidence.voice_processing_bypassed =
      bypassReadStatus != noErr || bypassReadbackSize != sizeof(bypassReadback) ||
      bypassReadback != 0;
  if (context->evidence.voice_processing_bypass_status != noErr ||
      context->evidence.voice_processing_bypassed) {
    if (context->evidence.voice_processing_bypass_status == noErr) {
      context->evidence.voice_processing_bypass_status = bypassReadStatus;
    }
    return false;
  }

  context->evidence.initialize_status = AudioUnitInitialize(context->vpio);
  if (context->evidence.initialize_status != noErr) {
    return false;
  }
  context->vpio_initialized = true;
  if (CancellationRequested()) {
    return false;
  }
  context->evidence.vpio_initialized_after_writer = context->writer_started;
  context->evidence.start_status = AudioOutputUnitStart(context->vpio);
  if (context->evidence.start_status != noErr) {
    return false;
  }
  context->vpio_started = true;
  if (CancellationRequested()) {
    return false;
  }
  context->evidence.endpoint_translation_stable_after_start =
      EndpointTranslationsStillMatch(context);
  context->evidence.defaults_stable_and_safe_after_vpio_start =
      InputDefaultStillVisibleAndStable(context) &&
      OutputDefaultsStillMatchAndAreSafe(context);
  if (!context->evidence.endpoint_translation_stable_after_start ||
      !context->evidence.defaults_stable_and_safe_after_vpio_start) {
    atomic_store_explicit(&context->io_gate_open, false, memory_order_release);
    return false;
  }
  atomic_store_explicit(&context->signal_enabled, true, memory_order_release);
  context->evidence.nonce_signal_enabled_after_vpio_start = true;
  return true;
}

static bool RunSignalWindow(ProbeContext *context) {
  const uint64_t start = MonotonicNanoseconds();
  uint64_t previousCallbackTotal = 0;
  uint64_t lastProgress = start;
  while (MonotonicNanoseconds() - start < kInternalRunDeadlineNanoseconds &&
         !CancellationRequested()) {
    const uint64_t writer = atomic_load_explicit(
        &context->writer_callback_count, memory_order_acquire);
    const uint64_t microphone = atomic_load_explicit(
        &context->microphone_callback_count, memory_order_acquire);
    const uint64_t output = atomic_load_explicit(
        &context->output_callback_count, memory_order_acquire);
    const uint64_t total = writer + microphone + output;
    const uint64_t now = MonotonicNanoseconds();
    if (total != previousCallbackTotal) {
      previousCallbackTotal = total;
      lastProgress = now;
    } else if (now - lastProgress > kCallbackStallNanoseconds) {
      atomic_fetch_add_explicit(&context->callback_stall_count, 1,
                                memory_order_relaxed);
      return false;
    }
    if (atomic_load_explicit(&context->input_listener_sequence,
                             memory_order_acquire) !=
            context->evidence.input_listener_sequence_at_commit ||
        atomic_load_explicit(&context->output_listener_sequence,
                             memory_order_acquire) != 0 ||
        atomic_load_explicit(&context->system_output_listener_sequence,
                             memory_order_acquire) != 0) {
      atomic_store_explicit(&context->io_gate_open, false,
                            memory_order_release);
      return false;
    }
    if (atomic_load_explicit(&context->capture_cursor, memory_order_acquire) >=
        kTargetCaptureFrames) {
      return true;
    }
    SleepMilliseconds(10);
  }
  atomic_fetch_add_explicit(&context->callback_stall_count, 1,
                            memory_order_relaxed);
  return false;
}

static uint64_t CallbackTotal(const ProbeContext *context) {
  return atomic_load_explicit(&context->writer_callback_count,
                              memory_order_acquire) +
         atomic_load_explicit(&context->microphone_callback_count,
                              memory_order_acquire) +
         atomic_load_explicit(&context->output_callback_count,
                              memory_order_acquire);
}

static bool WaitForCallbackDrain(const ProbeContext *context) {
  const uint64_t deadline = MonotonicNanoseconds() + UINT64_C(1000000000);
  while (MonotonicNanoseconds() < deadline) {
    const uint64_t inFlight =
        atomic_load_explicit(&context->writer_callbacks_in_flight,
                             memory_order_acquire) +
        atomic_load_explicit(&context->microphone_callbacks_in_flight,
                             memory_order_acquire) +
        atomic_load_explicit(&context->output_callbacks_in_flight,
                             memory_order_acquire);
    if (inFlight == 0) {
      return true;
    }
    SleepMilliseconds(5);
  }
  return false;
}

static bool InputDeviceMatchesAdmissibleUID(AudioDeviceID deviceID,
                                            const char *expectedUID) {
  if (deviceID == kAudioObjectUnknown || expectedUID == NULL ||
      OSVAPublicVPIOIsForbiddenRestorationInputUID(expectedUID)) {
    return false;
  }
  char readbackUID[256];
  UInt32 alive = 0;
  UInt32 hidden = 0;
  return CopyStringProperty(deviceID, kAudioDevicePropertyDeviceUID,
                            readbackUID, sizeof(readbackUID)) == noErr &&
         strcmp(readbackUID, expectedUID) == 0 &&
         ReadProperty(deviceID, kAudioDevicePropertyDeviceIsAlive,
                      kAudioObjectPropertyScopeGlobal, &alive,
                      (UInt32)sizeof(alive)) == noErr &&
         ReadProperty(deviceID, kAudioDevicePropertyIsHidden,
                      kAudioObjectPropertyScopeGlobal, &hidden,
                      (UInt32)sizeof(hidden)) == noErr &&
         alive != 0 && hidden == 0;
}

static void RestoreDefaultInputIfOwned(ProbeContext *context) {
  const uint64_t restoreSequence = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire);
  context->evidence.input_listener_sequence_at_restore = restoreSequence;
  if (restoreSequence > context->evidence.input_listener_sequence_at_commit) {
    context->evidence.unexpected_input_listener_notifications =
        restoreSequence - context->evidence.input_listener_sequence_at_commit;
  }

  AudioDeviceID current = kAudioObjectUnknown;
  const bool readCurrent =
      ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &current) ==
      noErr;
  const bool stillOwned =
      readCurrent && current == context->visible_device &&
      restoreSequence == context->evidence.input_listener_sequence_at_commit &&
      (!context->evidence.default_input_was_changed ||
       context->selection_write_succeeded);
  context->evidence.default_input_ownership_preserved_at_restore = stillOwned;

  AudioDeviceID freshRestorationTarget = kAudioObjectUnknown;
  context->evidence.restoration_target_retranslated_from_uid =
      TranslateExactDeviceUID(context->original_input_uid,
                              &freshRestorationTarget) == noErr &&
      InputDeviceMatchesAdmissibleUID(freshRestorationTarget,
                                      context->original_input_uid);

  if (!context->evidence.default_input_was_changed) {
    char currentUID[256];
    context->evidence.final_default_input_matches_snapshot =
        readCurrent &&
        context->evidence.restoration_target_retranslated_from_uid &&
        current == freshRestorationTarget &&
        CopyStringProperty(current, kAudioDevicePropertyDeviceUID, currentUID,
                           sizeof(currentUID)) == noErr &&
        strcmp(currentUID, context->original_input_uid) == 0;
    return;
  }
  if (!stillOwned) {
    context->evidence.restoration_skipped_after_ownership_loss = true;
    return;
  }
  if (!context->evidence.restoration_target_retranslated_from_uid) {
    return;
  }

  AudioDeviceID comparison = kAudioObjectUnknown;
  if (ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice,
                        &comparison) != noErr ||
      comparison != context->visible_device) {
    return;
  }
  context->evidence.restoration_attempted_if_owned = true;
  if (WriteDefaultInputDevice(freshRestorationTarget) != noErr) {
    return;
  }
  const bool readback = WaitForDefaultInput(
      freshRestorationTarget, restoreSequence,
      &context->input_listener_sequence, true, false);
  context->evidence.restoration_succeeded = readback;
  AudioDeviceID finalInput = kAudioObjectUnknown;
  char finalUID[256];
  context->evidence.final_default_input_matches_snapshot =
      readback &&
      ReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &finalInput) ==
          noErr &&
      finalInput == freshRestorationTarget &&
      CopyStringProperty(finalInput, kAudioDevicePropertyDeviceUID, finalUID,
                         sizeof(finalUID)) == noErr &&
      strcmp(finalUID, context->original_input_uid) == 0;
}

static void CollectCallbackEvidence(ProbeContext *context) {
  context->evidence.writer_callback_count = atomic_load_explicit(
      &context->writer_callback_count, memory_order_acquire);
  context->evidence.microphone_callback_count = atomic_load_explicit(
      &context->microphone_callback_count, memory_order_acquire);
  context->evidence.output_callback_count = atomic_load_explicit(
      &context->output_callback_count, memory_order_acquire);
  context->evidence.output_silence_frame_count = atomic_load_explicit(
      &context->output_silence_frame_count, memory_order_acquire);
  context->evidence.initial_silence_frames = atomic_load_explicit(
      &context->initial_silence_frames, memory_order_acquire);
  context->evidence.writer_valid_timestamp_count = atomic_load_explicit(
      &context->writer_valid_timestamp_count, memory_order_acquire);
  context->evidence.microphone_valid_timestamp_count = atomic_load_explicit(
      &context->microphone_valid_timestamp_count, memory_order_acquire);
  context->evidence.frozen_timestamp_count = atomic_load_explicit(
      &context->frozen_timestamp_count, memory_order_acquire);
  context->evidence.gapped_timestamp_count = atomic_load_explicit(
      &context->gapped_timestamp_count, memory_order_acquire);
  context->evidence.oversized_callback_count = atomic_load_explicit(
      &context->oversized_callback_count, memory_order_acquire);
  context->evidence.callback_stall_count = atomic_load_explicit(
      &context->callback_stall_count, memory_order_acquire);
  context->evidence.render_error_count = atomic_load_explicit(
      &context->render_error_count, memory_order_acquire);
  context->evidence.known_vpio_error_count = atomic_load_explicit(
      &context->known_vpio_error_count, memory_order_acquire);
  context->evidence.output_reference_is_bounded_silence =
      context->evidence.output_silence_frame_count > 0 &&
      context->evidence.oversized_callback_count == 0;
}

static void TeardownAndRestore(ProbeContext *context) {
  atomic_store_explicit(&context->io_gate_open, false, memory_order_release);
  atomic_store_explicit(&context->signal_enabled, false, memory_order_release);
  context->evidence.gates_closed_before_stop = true;

  if (context->vpio_started) {
    context->evidence.vpio_stop_status = AudioOutputUnitStop(context->vpio);
    if (context->evidence.vpio_stop_status == noErr) {
      context->vpio_started = false;
    }
  }
  if (context->writer_started) {
    context->evidence.writer_stop_status =
        AudioDeviceStop(context->hidden_device, context->writer_io_proc);
    if (context->evidence.writer_stop_status == noErr) {
      context->writer_started = false;
    }
  }

  const bool drained = WaitForCallbackDrain(context);
  context->evidence.callbacks_in_flight_after_drain =
      atomic_load_explicit(&context->writer_callbacks_in_flight,
                           memory_order_acquire) +
      atomic_load_explicit(&context->microphone_callbacks_in_flight,
                           memory_order_acquire) +
      atomic_load_explicit(&context->output_callbacks_in_flight,
                           memory_order_acquire);
  const uint64_t callbackTotalBefore = CallbackTotal(context);
  SleepMilliseconds(100);
  context->evidence.callbacks_stable_after_drain =
      drained && CallbackTotal(context) == callbackTotalBefore;

  if (context->vpio_initialized) {
    context->evidence.vpio_uninitialize_status =
        AudioUnitUninitialize(context->vpio);
    if (context->evidence.vpio_uninitialize_status == noErr) {
      context->vpio_initialized = false;
    }
  }
  if (context->vpio_created) {
    context->evidence.vpio_dispose_status =
        AudioComponentInstanceDispose(context->vpio);
    if (context->evidence.vpio_dispose_status == noErr) {
      context->vpio_created = false;
      context->vpio = NULL;
    }
  }
  if (context->writer_io_proc_created) {
    context->evidence.writer_destroy_status = AudioDeviceDestroyIOProcID(
        context->hidden_device, context->writer_io_proc);
    if (context->evidence.writer_destroy_status == noErr) {
      context->writer_io_proc_created = false;
      context->writer_io_proc = NULL;
    }
  }

  RestoreDefaultInputIfOwned(context);
  context->evidence.output_defaults_stable_and_safe_after_run =
      OutputDefaultsStillMatchAndAreSafe(context);
  const uint64_t listenerTotalBeforeRemoval = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire) +
      atomic_load_explicit(&context->output_listener_sequence,
                           memory_order_acquire) +
      atomic_load_explicit(&context->system_output_listener_sequence,
                           memory_order_acquire);
  context->evidence.listeners_removed = RemoveDefaultListeners(context);
  SleepMilliseconds(100);
  const uint64_t listenerTotalAfterRemoval = atomic_load_explicit(
      &context->input_listener_sequence, memory_order_acquire) +
      atomic_load_explicit(&context->output_listener_sequence,
                           memory_order_acquire) +
      atomic_load_explicit(&context->system_output_listener_sequence,
                           memory_order_acquire);
  context->evidence.listener_callbacks_stable_after_removal =
      listenerTotalBeforeRemoval == listenerTotalAfterRemoval;
  context->evidence.output_listener_notifications = atomic_load_explicit(
      &context->output_listener_sequence, memory_order_acquire);
  context->evidence.system_output_listener_notifications = atomic_load_explicit(
      &context->system_output_listener_sequence, memory_order_acquire);
}

static void AnalyzeCapture(ProbeContext *context) {
  size_t captureCount = (size_t)atomic_load_explicit(
      &context->capture_cursor, memory_order_acquire);
  if (captureCount > context->capture_capacity) {
    captureCount = context->capture_capacity;
  }
  const OSVAPublicVPIOSignalMetrics metrics = OSVAPublicVPIOAnalyzeSignal(
      context->signal, context->signal_frame_count, context->capture,
      captureCount);
  context->evidence.captured_frame_count = metrics.captured_frame_count;
  context->evidence.matched_envelope_frame_count =
      metrics.matched_envelope_frame_count;
  context->evidence.capture_hash = metrics.capture_hash;
  context->evidence.capture_rms = metrics.capture_rms;
  context->evidence.speech_band_correlation =
      metrics.speech_band_correlation;
}

static void PrintSelfTestJSON(OSVAPublicVPIOSelfTestSummary summary) {
  printf("{\"schema\":1,\"mode\":\"self-test\","
         "\"claim\":\"public-vpio-compatibility-only\","
         "\"passed\":%s,\"tests\":%u,\"mutants\":%u,"
         "\"passSetHash\":\"%016llx\","
         "\"unexpectedFailureMask\":\"%016llx\","
         "\"publicVPIOProcessedMicUplinkValidated\":false,"
         "\"publicVPIOStereoPlayoutRenderPathValidated\":false,"
         "\"faceTimeUplinkClaimed\":false,"
         "\"localDownlinkAcousticsClaimed\":false,"
         "\"farEndDownlinkAcousticsClaimed\":false}\n",
         summary.passed ? "true" : "false", summary.test_count,
         summary.mutant_count, (unsigned long long)summary.pass_set_hash,
         (unsigned long long)summary.unexpected_failure_mask);
}

static void PrintLiveJSON(const ProbeContext *context, uint64_t failures) {
  const OSVAPublicVPIOEvidence *e = &context->evidence;
  const bool processedMicRateFinite = isfinite(e->processed_mic_sample_rate);
  const bool playoutRateFinite = isfinite(e->playout_sample_rate);
  const bool captureMetricsFinite =
      isfinite(e->capture_rms) && isfinite(e->speech_band_correlation);
  const double printableProcessedMicRate =
      processedMicRateFinite ? e->processed_mic_sample_rate : 0.0;
  const double printablePlayoutRate =
      playoutRateFinite ? e->playout_sample_rate : 0.0;
  const double printableCaptureRMS = captureMetricsFinite ? e->capture_rms : 0.0;
  const double printableCorrelation =
      captureMetricsFinite ? e->speech_band_correlation : 0.0;
  printf(
      "{\"schema\":1,\"mode\":\"live-opt-in\","
      "\"claim\":\"public-vpio-compatibility-only\","
      "\"passed\":%s,\"failureMask\":\"%016llx\","
      "\"visibleUIDHash\":\"%016llx\","
      "\"hiddenUIDHash\":\"%016llx\","
      "\"modelUIDHash\":\"%016llx\","
      "\"nonceHash\":\"%016llx\",\"captureHash\":\"%016llx\","
      "\"visibleInputChannels\":%u,\"visibleOutputChannels\":%u,"
      "\"hiddenInputChannels\":%u,\"hiddenOutputChannels\":%u,"
      "\"visibleClockDomain\":%u,\"hiddenClockDomain\":%u,"
      "\"endpointTranslationStableBeforeCommit\":%s,"
      "\"endpointTranslationStableAfterStart\":%s,"
      "\"processedMicSampleRateFinite\":%s,"
      "\"processedMicSampleRate\":%.6f,\"processedMicChannels\":%u,"
      "\"playoutSampleRateFinite\":%s,"
      "\"playoutSampleRate\":%.6f,\"playoutChannels\":%u,"
      "\"visibleFormatStatus\":%d,\"hiddenFormatStatus\":%d,"
      "\"visibleNativeFormatExact\":%s,"
      "\"hiddenNativeFormatExact\":%s,"
      "\"processedMicClientFormatExact\":%s,"
      "\"processedMicFormatSetStatus\":%d,"
      "\"processedMicFormatReadStatus\":%d,"
      "\"playoutClientFormatExact\":%s,"
      "\"playoutFormatSetStatus\":%d,"
      "\"playoutFormatReadStatus\":%d,"
      "\"originalInputUIDHash\":\"%016llx\","
      "\"originalInputAdmissibleForRestoration\":%s,"
      "\"defaultOutputUIDHash\":\"%016llx\","
      "\"defaultSystemOutputUIDHash\":\"%016llx\","
      "\"defaultOutputForbidden\":%s,"
      "\"defaultSystemOutputForbidden\":%s,"
      "\"defaultOutputRealAndAlive\":%s,"
      "\"defaultSystemOutputRealAndAlive\":%s,"
      "\"defaultOutputPhysicalChannels\":%u,"
      "\"defaultSystemOutputPhysicalChannels\":%u,"
      "\"outputDefaultsStableAndSafeBeforeGate\":%s,"
      "\"defaultsStableAndSafeAfterVPIOStart\":%s,"
      "\"outputDefaultsStableAndSafeAfterRun\":%s,"
      "\"inputListenerBefore\":%llu,\"inputListenerCommit\":%llu,"
      "\"inputListenerRestore\":%llu,"
      "\"outputNotifications\":%llu,"
      "\"systemOutputNotifications\":%llu,"
      "\"unexpectedInputNotifications\":%llu,"
      "\"writerCreateStatus\":%d,\"writerStartStatus\":%d,"
      "\"writerCallbacks\":%llu,\"microphoneCallbacks\":%llu,"
      "\"outputCallbacks\":%llu,\"outputSilenceFrames\":%llu,"
      "\"initialSilenceFrames\":%llu,"
      "\"writerValidTimestamps\":%llu,"
      "\"microphoneValidTimestamps\":%llu,"
      "\"frozenTimestamps\":%llu,\"gappedTimestamps\":%llu,"
      "\"oversizedCallbacks\":%llu,\"callbackStalls\":%llu,"
      "\"capturedFrames\":%llu,"
      "\"matchedEnvelopeFrames\":%llu,\"captureMetricsFinite\":%s,"
      "\"captureRMS\":%.9f,"
      "\"speechBandCorrelation\":%.9f,\"lastRenderError\":%d,"
      "\"renderErrors\":%llu,\"knownVPIOErrors\":%llu,"
      "\"componentStatus\":%d,"
      "\"enableInputStatus\":%d,\"enableOutputStatus\":%d,"
      "\"inputCallbackStatus\":%d,\"outputCallbackStatus\":%d,"
      "\"voiceProcessingBypassStatus\":%d,"
      "\"voiceProcessingBypassed\":%s,"
      "\"initializeStatus\":%d,\"startStatus\":%d,"
      "\"restorationOwnershipPreserved\":%s,"
      "\"restorationTargetRetranslatedFromUID\":%s,"
      "\"restorationAttemptedIfOwned\":%s,"
      "\"restorationSucceeded\":%s,"
      "\"restorationSkippedAfterOwnershipLoss\":%s,"
      "\"finalDefaultInputMatchesSnapshot\":%s,"
      "\"gatesClosedBeforeStop\":%s,"
      "\"cancellationHandlersInstalled\":%s,"
      "\"vpioStopStatus\":%d,"
      "\"vpioUninitializeStatus\":%d,\"vpioDisposeStatus\":%d,"
      "\"writerStopStatus\":%d,\"writerDestroyStatus\":%d,"
      "\"callbacksInFlightAfterDrain\":%llu,"
      "\"callbacksStableAfterDrain\":%s,\"listenersRemoved\":%s,"
      "\"listenerCallbacksStableAfterRemoval\":%s,"
      "\"outputReferenceIsBoundedSilence\":%s,"
      "\"publicVPIOProcessedMicUplinkValidated\":%s,"
      "\"publicVPIOStereoPlayoutRenderPathValidated\":%s,"
      "\"faceTimeUplinkClaimed\":false,"
      "\"localDownlinkAcousticsClaimed\":false,"
      "\"farEndDownlinkAcousticsClaimed\":false}\n",
      failures == 0 ? "true" : "false", (unsigned long long)failures,
      (unsigned long long)e->visible_uid_hash,
      (unsigned long long)e->hidden_uid_hash,
      (unsigned long long)e->visible_model_uid_hash,
      (unsigned long long)e->nonce_hash,
      (unsigned long long)e->capture_hash, e->visible_input_channels,
      e->visible_output_channels, e->hidden_input_channels,
      e->hidden_output_channels, e->visible_clock_domain,
      e->hidden_clock_domain,
      e->endpoint_translation_stable_before_commit ? "true" : "false",
      e->endpoint_translation_stable_after_start ? "true" : "false",
      processedMicRateFinite ? "true" : "false", printableProcessedMicRate,
      e->processed_mic_channels,
      playoutRateFinite ? "true" : "false", printablePlayoutRate,
      e->playout_channels, e->visible_format_status,
      e->hidden_format_status,
      e->visible_stream_format_exact ? "true" : "false",
      e->hidden_stream_format_exact ? "true" : "false",
      e->processed_mic_stream_format_exact ? "true" : "false",
      e->processed_mic_format_set_status,
      e->processed_mic_format_read_status,
      e->playout_stream_format_exact ? "true" : "false",
      e->playout_format_set_status, e->playout_format_read_status,
      (unsigned long long)e->original_input_uid_hash,
      e->original_input_is_admissible_for_restoration ? "true" : "false",
      (unsigned long long)e->default_output_uid_hash,
      (unsigned long long)e->default_system_output_uid_hash,
      e->default_output_is_forbidden_virtual ? "true" : "false",
      e->default_system_output_is_forbidden_virtual ? "true" : "false",
      e->default_output_is_real_and_alive ? "true" : "false",
      e->default_system_output_is_real_and_alive ? "true" : "false",
      e->default_output_channels, e->default_system_output_channels,
      e->output_defaults_stable_and_safe_before_gate ? "true" : "false",
      e->defaults_stable_and_safe_after_vpio_start ? "true" : "false",
      e->output_defaults_stable_and_safe_after_run ? "true" : "false",
      (unsigned long long)e->input_listener_sequence_before_selection,
      (unsigned long long)e->input_listener_sequence_at_commit,
      (unsigned long long)e->input_listener_sequence_at_restore,
      (unsigned long long)e->output_listener_notifications,
      (unsigned long long)e->system_output_listener_notifications,
      (unsigned long long)e->unexpected_input_listener_notifications,
      e->writer_create_status, e->writer_start_status,
      (unsigned long long)e->writer_callback_count,
      (unsigned long long)e->microphone_callback_count,
      (unsigned long long)e->output_callback_count,
      (unsigned long long)e->output_silence_frame_count,
      (unsigned long long)e->initial_silence_frames,
      (unsigned long long)e->writer_valid_timestamp_count,
      (unsigned long long)e->microphone_valid_timestamp_count,
      (unsigned long long)e->frozen_timestamp_count,
      (unsigned long long)e->gapped_timestamp_count,
      (unsigned long long)e->oversized_callback_count,
      (unsigned long long)e->callback_stall_count,
      (unsigned long long)e->captured_frame_count,
      (unsigned long long)e->matched_envelope_frame_count,
      captureMetricsFinite ? "true" : "false", printableCaptureRMS,
      printableCorrelation, e->last_render_error,
      (unsigned long long)e->render_error_count,
      (unsigned long long)e->known_vpio_error_count, e->component_status,
      e->enable_input_status, e->enable_output_status,
      e->input_callback_status, e->output_callback_status,
      e->voice_processing_bypass_status,
      e->voice_processing_bypassed ? "true" : "false",
      e->initialize_status, e->start_status,
      e->default_input_ownership_preserved_at_restore ? "true" : "false",
      e->restoration_target_retranslated_from_uid ? "true" : "false",
      e->restoration_attempted_if_owned ? "true" : "false",
      e->restoration_succeeded ? "true" : "false",
      e->restoration_skipped_after_ownership_loss ? "true" : "false",
      e->final_default_input_matches_snapshot ? "true" : "false",
      e->gates_closed_before_stop ? "true" : "false",
      e->cancellation_handlers_installed ? "true" : "false",
      e->vpio_stop_status,
      e->vpio_uninitialize_status, e->vpio_dispose_status,
      e->writer_stop_status, e->writer_destroy_status,
      (unsigned long long)e->callbacks_in_flight_after_drain,
      e->callbacks_stable_after_drain ? "true" : "false",
      e->listeners_removed ? "true" : "false",
      e->listener_callbacks_stable_after_removal ? "true" : "false",
      e->output_reference_is_bounded_silence ? "true" : "false",
      failures == 0 ? "true" : "false",
      failures == 0 ? "true" : "false");
}

static int RunLiveProbe(void) {
  struct sigaction cancellationAction;
  memset(&cancellationAction, 0, sizeof(cancellationAction));
  cancellationAction.sa_handler = HandleCancellationSignal;
  sigemptyset(&cancellationAction.sa_mask);
  cancellationAction.sa_flags = 0;
  const int termHandlerStatus =
      sigaction(SIGTERM, &cancellationAction, NULL);
  const int interruptHandlerStatus =
      sigaction(SIGINT, &cancellationAction, NULL);

  ProbeContext context;
  memset(&context, 0, sizeof(context));
  context.evidence.cancellation_handlers_installed =
      termHandlerStatus == 0 && interruptHandlerStatus == 0;
  context.signal_frame_count = kSignalFrameCount;
  context.capture_capacity = kSignalFrameCount;
  context.signal =
      (float *)calloc(context.signal_frame_count, sizeof(float));
  context.capture =
      (float *)calloc(context.capture_capacity, sizeof(float));
  bool setupSucceeded = context.evidence.cancellation_handlers_installed &&
                        context.signal != NULL && context.capture != NULL;
  if (setupSucceeded) {
    GenerateNonceSignal(&context);
    setupSucceeded = !CancellationRequested();
  }

  if (setupSucceeded) {
    setupSucceeded = RegisterDefaultListeners(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = ReadDefaultSnapshot(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = ResolveExactEndpoints(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = PopulateEndpointEvidence(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = PopulateOutputEvidence(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = StartHiddenWriter(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = SelectVisibleDefaultInput(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = ConfigureAndStartVPIO(&context);
  }
  if (setupSucceeded) {
    setupSucceeded = RunSignalWindow(&context);
  }
  setupSucceeded = setupSucceeded && !CancellationRequested();

  if (context.vpio_created) {
    SInt32 lastRenderError = noErr;
    UInt32 size = (UInt32)sizeof(lastRenderError);
    const OSStatus status = AudioUnitGetProperty(
        context.vpio, kAudioUnitProperty_LastRenderError,
        kAudioUnitScope_Global, 0, &lastRenderError, &size);
    context.evidence.last_render_error =
        status == noErr && size == sizeof(lastRenderError) ? lastRenderError
                                                           : status;
  }

  TeardownAndRestore(&context);
  CollectCallbackEvidence(&context);
  AnalyzeCapture(&context);
  const uint64_t failures = OSVAPublicVPIOEvaluate(&context.evidence);
  PrintLiveJSON(&context, failures);
  free(context.signal);
  free(context.capture);
  return setupSucceeded && failures == 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
  if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
    const OSVAPublicVPIOSelfTestSummary summary =
        OSVAPublicVPIORunSelfTests();
    PrintSelfTestJSON(summary);
    return summary.passed ? 0 : 1;
  }
  if (argc == 3 && strcmp(argv[1], "--live") == 0 &&
      strcmp(argv[2], "--acknowledge-default-input-mutation") == 0) {
    const char *permission = getenv("OSVA_PUBLIC_VPIO_LIVE");
    if (permission == NULL ||
        strcmp(permission,
               "I_UNDERSTAND_THIS_TEMPORARILY_CHANGES_DEFAULT_INPUT") != 0) {
      fprintf(stderr,
              "live mode requires the exact OSVA_PUBLIC_VPIO_LIVE opt-in\n");
      return 64;
    }
    return RunLiveProbe();
  }
  fprintf(stderr,
          "usage: %s --self-test | --live "
          "--acknowledge-default-input-mutation\n",
          argv[0]);
  return 64;
}
