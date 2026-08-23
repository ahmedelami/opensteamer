#ifndef OPENSTEAMER_VIRTUAL_MICROPHONE_DRIVER_H
#define OPENSTEAMER_VIRTUAL_MICROPHONE_DRIVER_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

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

enum {
  kOSVAClockDomain = 0x6F73564D,
  kOSVAZeroTimeStampPeriodFrames = 16384,
  kOSVARingCapacityFrames = 131072,
};

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
#endif

#ifdef __cplusplus
}
#endif

#endif
