#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static volatile sig_atomic_t gRunning = 1;
static uint64_t gCallbacks = 0;
static double gLastRMS = 0;
static double gLastPeak = 0;

static void stopProbe(int signal) {
    (void)signal;
    gRunning = 0;
}

static void printStatus(OSStatus status, const char *operation) {
    char code[5] = {
        (char)((status >> 24) & 0xff),
        (char)((status >> 16) & 0xff),
        (char)((status >> 8) & 0xff),
        (char)(status & 0xff),
        0
    };
    fprintf(stderr, "%s failed: %d (%s)\n", operation, status, code);
}

static AudioObjectID defaultOutputDevice(void) {
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &size,
        &deviceID
    );
    if (status != noErr) {
        printStatus(status, "AudioObjectGetPropertyData(defaultOutputDevice)");
        return kAudioObjectUnknown;
    }
    return deviceID;
}

static NSString *deviceUID(AudioObjectID deviceID) {
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &uid);
    if (status != noErr || uid == NULL) {
        printStatus(status, "AudioObjectGetPropertyData(deviceUID)");
        return nil;
    }

    NSString *result = [(__bridge NSString *)uid copy];
    CFRelease(uid);
    return result;
}

static void printTapFormat(AudioObjectID tap) {
    AudioStreamBasicDescription description;
    UInt32 size = sizeof(description);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioTapPropertyFormat,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, &description);
    if (status != noErr) {
        printStatus(status, "AudioObjectGetPropertyData(kAudioTapPropertyFormat)");
        return;
    }

    printf(
        "tapFormat sampleRate=%.1f channels=%u bytesPerFrame=%u bitsPerChannel=%u flags=0x%x\n",
        description.mSampleRate,
        description.mChannelsPerFrame,
        description.mBytesPerFrame,
        description.mBitsPerChannel,
        description.mFormatFlags
    );
}

static OSStatus probeIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;
    (void)inClientData;

    double sumSquares = 0;
    double peak = 0;
    uint64_t samples = 0;

    for (UInt32 bufferIndex = 0; bufferIndex < inInputData->mNumberBuffers; bufferIndex++) {
        const AudioBuffer buffer = inInputData->mBuffers[bufferIndex];
        const float *data = (const float *)buffer.mData;
        if (data == NULL) {
            continue;
        }

        UInt32 sampleCount = buffer.mDataByteSize / sizeof(float);
        for (UInt32 index = 0; index < sampleCount; index++) {
            double value = data[index];
            double magnitude = fabs(value);
            peak = fmax(peak, magnitude);
            sumSquares += value * value;
            samples += 1;
        }
    }

    gCallbacks += 1;
    gLastRMS = samples > 0 ? sqrt(sumSquares / (double)samples) : 0;
    gLastPeak = peak;
    return noErr;
}

int main(int argc, const char *argv[]) {
    signal(SIGINT, stopProbe);
    signal(SIGTERM, stopProbe);

    int durationSeconds = argc > 1 ? atoi(argv[1]) : 15;
    AudioObjectID tap = 0;
    AudioObjectID aggregateDevice = 0;
    AudioDeviceIOProcID ioProcID = NULL;
    OSStatus status = noErr;

    @autoreleasepool {
        NSArray<NSNumber *> *excludedProcesses = @[];
        CATapDescription *tapDescription = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excludedProcesses];
        if (tapDescription == nil) {
            fprintf(stderr, "failed to create CATapDescription\n");
            return 2;
        }

        tapDescription.name = @"AudioStreamerTapProbe";
        tapDescription.UUID = [NSUUID UUID];
        tapDescription.private = YES;
        tapDescription.exclusive = YES;
        tapDescription.muteBehavior = CATapUnmuted;

        status = AudioHardwareCreateProcessTap(tapDescription, &tap);
        if (status != noErr) {
            printStatus(status, "AudioHardwareCreateProcessTap");
            return 3;
        }
        printTapFormat(tap);

        AudioObjectID outputDevice = defaultOutputDevice();
        NSString *outputUID = outputDevice == kAudioObjectUnknown ? nil : deviceUID(outputDevice);
        if (outputUID == nil) {
            AudioHardwareDestroyProcessTap(tap);
            return 4;
        }
        printf("defaultOutputDevice=%u uid=%s\n", outputDevice, [outputUID UTF8String]);

        NSString *tapUID = tapDescription.UUID.UUIDString;
        NSDictionary *tapEntry = @{
            @kAudioSubTapUIDKey: tapUID,
            @kAudioSubTapDriftCompensationKey: @YES
        };
        NSDictionary *aggregateDescription = @{
            @kAudioAggregateDeviceNameKey: @"AudioStreamerTapProbeAggregate",
            @kAudioAggregateDeviceUIDKey: [NSString stringWithFormat:@"org.example.AudioStreamer.TapProbe.Aggregate.%@", [NSUUID UUID].UUIDString],
            @kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[
                @{
                    @kAudioSubDeviceUIDKey: outputUID
                }
            ],
            @kAudioAggregateDeviceTapListKey: @[tapEntry],
            @kAudioAggregateDeviceTapAutoStartKey: @YES,
            @kAudioAggregateDeviceIsStackedKey: @NO,
            @kAudioAggregateDeviceIsPrivateKey: @YES
        };

        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription, &aggregateDevice);
        if (status != noErr) {
            printStatus(status, "AudioHardwareCreateAggregateDevice");
            AudioHardwareDestroyProcessTap(tap);
            return 4;
        }
        printf("aggregateDevice=%u created\n", aggregateDevice);

        status = AudioDeviceCreateIOProcID(aggregateDevice, probeIOProc, NULL, &ioProcID);
        if (status != noErr) {
            printStatus(status, "AudioDeviceCreateIOProcID");
            AudioHardwareDestroyAggregateDevice(aggregateDevice);
            AudioHardwareDestroyProcessTap(tap);
            return 5;
        }

        printf("starting aggregate device; play audio now if auto-start waits for first frames\n");
        fflush(stdout);
        status = AudioDeviceStart(aggregateDevice, ioProcID);
        if (status != noErr) {
            printStatus(status, "AudioDeviceStart");
            AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID);
            AudioHardwareDestroyAggregateDevice(aggregateDevice);
            AudioHardwareDestroyProcessTap(tap);
            return 6;
        }

        for (int elapsed = 0; gRunning && elapsed < durationSeconds; elapsed++) {
            sleep(1);
            double dbFS = gLastRMS > 0 ? 20.0 * log10(gLastRMS) : -INFINITY;
            printf(
                "tapProbe callbacks=%llu rms=%.6f peak=%.6f dbFS=%s%.1f\n",
                gCallbacks,
                gLastRMS,
                gLastPeak,
                isinf(dbFS) ? "-" : "",
                isinf(dbFS) ? INFINITY : dbFS
            );
            fflush(stdout);
        }

        AudioDeviceStop(aggregateDevice, ioProcID);
        AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID);
        AudioHardwareDestroyAggregateDevice(aggregateDevice);
        AudioHardwareDestroyProcessTap(tap);
    }

    return 0;
}
