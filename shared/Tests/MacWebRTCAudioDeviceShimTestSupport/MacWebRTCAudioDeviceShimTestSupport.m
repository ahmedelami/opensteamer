#import "MacWebRTCAudioDeviceShimTestSupport.h"

#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^LKRTCAudioDeviceGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags *,
    const AudioTimeStamp *,
    NSInteger,
    UInt32,
    AudioBufferList *
);
typedef OSStatus (^LKRTCAudioDeviceRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags *,
    const AudioTimeStamp *,
    NSInteger,
    UInt32,
    AudioBufferList *,
    void *_Nullable
);
typedef OSStatus (^LKRTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *,
    const AudioTimeStamp *,
    NSInteger,
    UInt32,
    const AudioBufferList *_Nullable,
    void *_Nullable,
    LKRTCAudioDeviceRenderRecordedDataBlock _Nullable
);

@protocol LKRTCAudioDeviceDelegate <NSObject>
@property(readonly, nonnull) LKRTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) LKRTCAudioDeviceGetPlayoutDataBlock getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol LKRTCAudioDevice <NSObject>
- (BOOL)initializeWithDelegate:(id<LKRTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
- (BOOL)initializeRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
- (BOOL)initializePlayout;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@end

@interface ASMacStereoAudioDevice (TestLifecycle) <LKRTCAudioDevice>
@end

@interface ASMacStereoAudioDeviceTestHarness () <LKRTCAudioDeviceDelegate> {
    pthread_mutex_t _mutex;
    ASMacStereoAudioDeviceHarnessDiagnostics _diagnostics;
    Float64 _expectedSampleTime;
    Float64 _expectedPlayoutSampleTime;
    uint64_t _expectedSourceFrame;
    ASMacStereoAudioDeviceHarnessDeliveryBehavior _deliveryBehavior;
    LKRTCAudioDeviceDeliverRecordedDataBlock _deliverRecordedData;
    LKRTCAudioDeviceGetPlayoutDataBlock _getPlayoutData;
}
@property(nonatomic, strong) ASMacStereoAudioDevice *device;
@end

typedef struct ASMacStereoThreadDeliveryContext {
    __unsafe_unretained ASMacStereoAudioDevice *device;
    uint64_t startFrame;
    NSUInteger frameCount;
    BOOL succeeded;
} ASMacStereoThreadDeliveryContext;

static void *_Nullable ASDeliverStereoSequenceOnThread(void *opaqueContext) {
    ASMacStereoThreadDeliveryContext *context = opaqueContext;
    const NSUInteger sampleCount = context->frameCount * 2;
    int16_t *samples = calloc(sampleCount, sizeof(int16_t));
    if (samples == NULL) {
        context->succeeded = NO;
        return NULL;
    }
    for (NSUInteger frame = 0; frame < context->frameCount; frame += 1) {
        const int16_t marker = (int16_t)(((context->startFrame + frame) % 30000) + 1);
        samples[frame * 2] = marker;
        samples[frame * 2 + 1] = -marker;
    }
    context->succeeded = [context->device deliverInterleavedStereoInt16:samples
                                                              frameCount:context->frameCount];
    free(samples);
    return NULL;
}

@implementation ASMacStereoAudioDeviceTestHarness

- (instancetype)initWithDevice:(ASMacStereoAudioDevice *)device {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _device = device;
    if (pthread_mutex_init(&_mutex, NULL) != 0) {
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    _deliverRecordedData = ^OSStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timestamp,
        NSInteger inputBusNumber,
        UInt32 frameCount,
        const AudioBufferList *inputData,
        void *renderContext,
        LKRTCAudioDeviceRenderRecordedDataBlock renderBlock
    ) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return kAudio_ParamError;
        }
        if (inputData != NULL) {
            pthread_mutex_lock(&strongSelf->_mutex);
            strongSelf->_diagnostics.directInputDataCallbackCount += 1;
            pthread_mutex_unlock(&strongSelf->_mutex);
            return [strongSelf inspectTimestamp:timestamp
                                    frameCount:frameCount
                                     inputData:inputData];
        }
        if (renderBlock == nil) {
            return kAudio_ParamError;
        }

        pthread_mutex_lock(&strongSelf->_mutex);
        const ASMacStereoAudioDeviceHarnessDeliveryBehavior behavior =
            strongSelf->_deliveryBehavior;
        pthread_mutex_unlock(&strongSelf->_mutex);
        if (behavior
            == ASMacStereoAudioDeviceHarnessDeliveryBehaviorReturnSuccessWithoutRender) {
            return noErr;
        }

        const size_t sampleCount = (size_t)frameCount * 2;
        int16_t *renderedSamples = calloc(sampleCount, sizeof(int16_t));
        if (renderedSamples == NULL) {
            return kAudio_MemFullError;
        }
        AudioBufferList renderedData = {0};
        renderedData.mNumberBuffers = 1;
        renderedData.mBuffers[0].mNumberChannels = behavior
                == ASMacStereoAudioDeviceHarnessDeliveryBehaviorReturnSuccessAfterInvalidRender
            ? 1
            : 2;
        renderedData.mBuffers[0].mDataByteSize =
            (UInt32)(sampleCount * sizeof(int16_t));
        renderedData.mBuffers[0].mData = renderedSamples;
        const NSUInteger invocationCount = behavior
                == ASMacStereoAudioDeviceHarnessDeliveryBehaviorInvokeRenderTwice
            ? 2
            : 1;
        OSStatus renderStatus = noErr;
        for (NSUInteger invocation = 0; invocation < invocationCount; invocation += 1) {
            renderStatus = renderBlock(
                actionFlags,
                timestamp,
                inputBusNumber,
                frameCount,
                &renderedData,
                renderContext
            );
            if (renderStatus == noErr) {
                pthread_mutex_lock(&strongSelf->_mutex);
                strongSelf->_diagnostics.renderBlockCallbackCount += 1;
                strongSelf->_diagnostics.renderedSampleElementCount += (uint64_t)sampleCount;
                pthread_mutex_unlock(&strongSelf->_mutex);
            }
            if (renderStatus != noErr) {
                break;
            }
        }
        if (behavior
            == ASMacStereoAudioDeviceHarnessDeliveryBehaviorReturnSuccessAfterInvalidRender) {
            free(renderedSamples);
            return noErr;
        }
        if (renderStatus != noErr) {
            free(renderedSamples);
            return renderStatus;
        }
        const OSStatus inspectStatus = [strongSelf inspectTimestamp:timestamp
                                                       frameCount:frameCount
                                                        inputData:&renderedData];
        free(renderedSamples);
        return inspectStatus;
    };
    _getPlayoutData = ^OSStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timestamp,
        NSInteger inputBusNumber,
        UInt32 frameCount,
        AudioBufferList *outputData
    ) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || outputData == NULL) {
            return kAudio_ParamError;
        }
        pthread_mutex_lock(&strongSelf->_mutex);
        strongSelf->_diagnostics.playoutCallbackCount += 1;
        strongSelf->_diagnostics.lastPlayoutFrameCount = frameCount;
        const BOOL timestampIsValid = timestamp != NULL
            && (timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0
            && (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0;
        if (!timestampIsValid
            || timestamp->mSampleTime != strongSelf->_expectedPlayoutSampleTime) {
            strongSelf->_diagnostics.playoutSampleTimeDiscontinuityCount += 1;
        }
        if (!timestampIsValid
            || (strongSelf->_diagnostics.playoutCallbackCount > 1
                && timestamp->mHostTime <= strongSelf->_diagnostics.lastPlayoutHostTime)) {
            strongSelf->_diagnostics.playoutHostTimeDiscontinuityCount += 1;
        }
        if (timestamp != NULL) {
            strongSelf->_diagnostics.lastPlayoutSampleTime = timestamp->mSampleTime;
            strongSelf->_diagnostics.lastPlayoutHostTime = timestamp->mHostTime;
        }
        strongSelf->_expectedPlayoutSampleTime += frameCount;
        pthread_mutex_unlock(&strongSelf->_mutex);
        for (UInt32 index = 0; index < outputData->mNumberBuffers; index += 1) {
            AudioBuffer *buffer = &outputData->mBuffers[index];
            if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
                memset(buffer->mData, 0, buffer->mDataByteSize);
            }
        }
        return noErr;
    };
    return self;
}

- (ASMacStereoAudioDeviceHarnessDeliveryBehavior)deliveryBehavior {
    pthread_mutex_lock(&_mutex);
    const ASMacStereoAudioDeviceHarnessDeliveryBehavior value = _deliveryBehavior;
    pthread_mutex_unlock(&_mutex);
    return value;
}

- (void)setDeliveryBehavior:(ASMacStereoAudioDeviceHarnessDeliveryBehavior)deliveryBehavior {
    pthread_mutex_lock(&_mutex);
    _deliveryBehavior = deliveryBehavior;
    pthread_mutex_unlock(&_mutex);
}

- (void)dealloc {
    [_device terminateDevice];
    pthread_mutex_destroy(&_mutex);
}

- (BOOL)startRecording {
    pthread_mutex_lock(&_mutex);
    _expectedSampleTime = 0;
    _expectedSourceFrame = 0;
    pthread_mutex_unlock(&_mutex);
    return [_device initializeWithDelegate:self]
        && [_device initializeRecording]
        && [_device startRecording]
        && [_device approveCurrentRecordingGeneration];
}

- (BOOL)repeatStartRecording {
    return [_device startRecording];
}

- (BOOL)restartRecording {
    return [_device stopRecording] && [self startRecording];
}

- (BOOL)restartRecordingWithoutApproval {
    if (![_device stopRecording]) {
        return NO;
    }
    pthread_mutex_lock(&_mutex);
    _expectedSampleTime = 0;
    _expectedSourceFrame = 0;
    pthread_mutex_unlock(&_mutex);
    return [_device initializeWithDelegate:self]
        && [_device initializeRecording]
        && [_device startRecording];
}

- (BOOL)approveCurrentRecordingGeneration {
    return [_device approveCurrentRecordingGeneration];
}

- (BOOL)stopRecording {
    return [_device stopRecording];
}

- (BOOL)startPlayout {
    pthread_mutex_lock(&_mutex);
    _expectedPlayoutSampleTime = 0;
    pthread_mutex_unlock(&_mutex);
    return [_device initializeWithDelegate:self]
        && [_device initializePlayout]
        && [_device startPlayout];
}

- (BOOL)repeatStartPlayout {
    return [_device startPlayout];
}

- (BOOL)stopPlayout {
    return [_device stopPlayout];
}

- (BOOL)deliverStereoSequenceOnNewThreadStartingAtFrame:(uint64_t)startFrame
                                             frameCount:(NSUInteger)frameCount {
    ASMacStereoThreadDeliveryContext context = {
        .device = _device,
        .startFrame = startFrame,
        .frameCount = frameCount,
        .succeeded = NO,
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, ASDeliverStereoSequenceOnThread, &context) != 0) {
        return NO;
    }
    if (pthread_join(thread, NULL) != 0) {
        return NO;
    }
    return context.succeeded;
}

- (ASMacStereoAudioDeviceHarnessDiagnostics)diagnostics {
    pthread_mutex_lock(&_mutex);
    const ASMacStereoAudioDeviceHarnessDiagnostics value = _diagnostics;
    pthread_mutex_unlock(&_mutex);
    return value;
}

- (OSStatus)inspectTimestamp:(const AudioTimeStamp *)timestamp
                  frameCount:(UInt32)frameCount
                   inputData:(const AudioBufferList *)inputData {
    pthread_mutex_lock(&_mutex);
    _diagnostics.callbackCount += 1;
    _diagnostics.frameCount += frameCount;
    _diagnostics.lastFrameCount = frameCount;

    const BOOL timestampIsValid = timestamp != NULL
        && (timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0
        && (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0;
    if (!timestampIsValid || timestamp->mSampleTime != _expectedSampleTime) {
        _diagnostics.sampleTimeDiscontinuityCount += 1;
    }
    if (!timestampIsValid
        || (_diagnostics.callbackCount > 1
            && timestamp->mHostTime <= _diagnostics.lastHostTime)) {
        _diagnostics.hostTimeDiscontinuityCount += 1;
    }
    if (timestamp != NULL) {
        _diagnostics.lastSampleTime = timestamp->mSampleTime;
        _diagnostics.lastHostTime = timestamp->mHostTime;
    }
    _expectedSampleTime += frameCount;

    const NSUInteger requiredBytes =
        (NSUInteger)frameCount * 2 * sizeof(int16_t);
    const BOOL listIsValid = inputData != NULL
        && inputData->mNumberBuffers == 1
        && inputData->mBuffers[0].mNumberChannels == 2
        && inputData->mBuffers[0].mDataByteSize == requiredBytes
        && inputData->mBuffers[0].mData != NULL;
    if (!listIsValid) {
        _diagnostics.invalidBufferListCount += 1;
        pthread_mutex_unlock(&_mutex);
        return kAudio_ParamError;
    }

    const int16_t *samples = inputData->mBuffers[0].mData;
    for (UInt32 frame = 0; frame < frameCount; frame += 1) {
        const int16_t marker = (int16_t)((_expectedSourceFrame % 30000) + 1);
        if (samples[frame * 2] != marker || samples[frame * 2 + 1] != -marker) {
            _diagnostics.samplePatternMismatchCount += 1;
        }
        _expectedSourceFrame += 1;
    }
    pthread_mutex_unlock(&_mutex);
    return noErr;
}

- (LKRTCAudioDeviceDeliverRecordedDataBlock)deliverRecordedData {
    return _deliverRecordedData;
}
- (LKRTCAudioDeviceGetPlayoutDataBlock)getPlayoutData { return _getPlayoutData; }
- (double)preferredInputSampleRate { return 48000; }
- (NSTimeInterval)preferredInputIOBufferDuration { return 0.010; }
- (double)preferredOutputSampleRate { return 48000; }
- (NSTimeInterval)preferredOutputIOBufferDuration { return 0.010; }
- (void)notifyAudioInputParametersChange {}
- (void)notifyAudioOutputParametersChange {}
- (void)notifyAudioInputInterrupted {
    pthread_mutex_lock(&_mutex);
    _diagnostics.inputInterruptionNotificationCount += 1;
    pthread_mutex_unlock(&_mutex);
}
- (void)notifyAudioOutputInterrupted {
    pthread_mutex_lock(&_mutex);
    _diagnostics.outputInterruptionNotificationCount += 1;
    pthread_mutex_unlock(&_mutex);
}
- (void)dispatchAsync:(dispatch_block_t)block { block(); }
- (void)dispatchSync:(dispatch_block_t)block { block(); }

@end

BOOL ASStartMacStereoDeviceRecordingWithoutStartingNativeADM(
    ASMacStereoAudioDevice *device
) {
    return device != nil
        && [device initializeRecording]
        && [device startRecording]
        && [device approveCurrentRecordingGeneration];
}

NS_ASSUME_NONNULL_END
