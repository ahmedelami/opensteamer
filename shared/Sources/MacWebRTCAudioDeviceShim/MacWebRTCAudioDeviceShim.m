#import "RTCAudioDeviceCompat.h"
#import "MacWebRTCAudioDeviceShim.h"

#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>
#import <string.h>

NSErrorDomain const ASMacWebRTCAudioDeviceErrorDomain = @"AudioStreamer.MacWebRTCAudioDevice";

static const double ASAudioSampleRate = 48000.0;
static const NSTimeInterval ASAudioIOBufferDuration = 0.010;
enum { ASAudioChannelCount = 2 };

typedef struct ASMacStereoRenderContext {
    const int16_t *samples;
    UInt32 frameCount;
    UInt32 byteCount;
    uint64_t invocationCount;
    uint64_t copiedFrameCount;
    uint64_t copiedSampleElementCount;
    uint64_t validationFailureCount;
} ASMacStereoRenderContext;

// A no-capture global block is emitted as _NSConcreteGlobalBlock. The synchronous native
// render-block contract passes the stack context below straight back to this block, avoiding a
// per-source-callback stack Block_copy/heap allocation on the live audio path.
static LKRTCAudioDeviceRenderRecordedDataBlock const ASRenderStereoRecordedData = ^OSStatus(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *renderData,
    void *opaqueContext
) {
    (void)actionFlags;
    (void)timestamp;
    (void)inputBusNumber;
    ASMacStereoRenderContext *context = opaqueContext;
    if (context == NULL) {
        return kAudio_ParamError;
    }
    context->invocationCount += 1;
    if (context->samples == NULL
        || frameCount != context->frameCount
        || context->byteCount
            != context->frameCount * ASAudioChannelCount * sizeof(int16_t)
        || renderData == NULL
        || renderData->mNumberBuffers != 1
        || renderData->mBuffers[0].mNumberChannels != ASAudioChannelCount
        || renderData->mBuffers[0].mDataByteSize < context->byteCount
        || renderData->mBuffers[0].mData == NULL) {
        context->validationFailureCount += 1;
        return kAudio_ParamError;
    }
    memcpy(renderData->mBuffers[0].mData, context->samples, context->byteCount);
    renderData->mBuffers[0].mDataByteSize = context->byteCount;
    context->copiedFrameCount += frameCount;
    context->copiedSampleElementCount +=
        (uint64_t)frameCount * ASAudioChannelCount;
    return noErr;
};

typedef struct ASMacStereoAudioDeviceState {
    // Lifecycle and callback entry are serialized independently from diagnostics. Holding the
    // lifecycle mutex through the native callback prevents a delivery from racing StopRecording.
    pthread_mutex_t lifecycleMutex;
    pthread_mutex_t stateMutex;

    atomic_bool initialized;
    atomic_bool recordingInitialized;
    atomic_bool recording;
    atomic_bool playoutInitialized;
    atomic_bool playing;

    pthread_t deliveryThread;
    BOOL deliveryThreadIsValid;
    pthread_t playoutThread;
    BOOL playoutThreadIsValid;

    Float64 nextDeliverySampleTime;
    uint64_t lastDeliveryHostTime;
    Float64 nextPlayoutSampleTime;
    uint64_t lastPlayoutHostTime;

    uint64_t receivedFrameCount;
    uint64_t deliveredFrameCount;
    uint64_t rejectedFrameCount;
    uint64_t deliveryCallbackCount;
    uint64_t deliveryFailureCount;
    uint64_t nativeDeliveryErrorCount;
    uint64_t renderInvocationCount;
    uint64_t renderCopiedFrameCount;
    uint64_t renderCopiedSampleElementCount;
    uint64_t renderNotInvokedCount;
    uint64_t renderMultipleInvocationCount;
    uint64_t renderValidationFailureCount;
    uint64_t prefilledInputDataDeliveryCount;
    uint64_t timestampResetCount;
    uint64_t recordingGeneration;
    uint64_t approvedRecordingGeneration;
    uint64_t admissionBlockedFrameCount;
    uint64_t inputInterruptionCount;
    uint64_t deliveryThreadChangeCount;
    uint32_t lastDeliveryFrameCount;
    Float64 lastDeliverySampleTime;
    uint64_t playoutCallbackCount;
    uint64_t playoutFrameCount;
    uint64_t playoutFailureCount;
} ASMacStereoAudioDeviceState;

static NSError *ASPreflightError(
    ASMacWebRTCAudioDeviceError code,
    NSString *description
) {
    return [NSError errorWithDomain:ASMacWebRTCAudioDeviceErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL ASMethodHasTypeEncoding(Class cls, SEL selector, const char *expected) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }
    const char *actual = method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, expected) == 0;
}

static uint64_t ASStrictlyIncreasingHostTime(uint64_t previous) {
    const uint64_t now = mach_absolute_time();
    return now > previous ? now : previous + 1;
}

static void ASNotifyInputInterrupted(id<LKRTCAudioDeviceDelegate> delegate) {
    [delegate dispatchSync:^{
        [delegate notifyAudioInputInterrupted];
    }];
}

static void ASNotifyOutputInterrupted(id<LKRTCAudioDeviceDelegate> delegate) {
    [delegate dispatchSync:^{
        [delegate notifyAudioOutputInterrupted];
    }];
}

@interface ASMacStereoAudioDevice () <LKRTCAudioDevice> {
    ASMacStereoAudioDeviceState *_state;
}
@property(atomic, strong, nullable) id<LKRTCAudioDeviceDelegate> delegate;
@end

@implementation ASMacStereoAudioDevice

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _state = calloc(1, sizeof(ASMacStereoAudioDeviceState));
    if (_state == NULL) {
        return nil;
    }
    if (pthread_mutex_init(&_state->lifecycleMutex, NULL) != 0) {
        free(_state);
        _state = NULL;
        return nil;
    }
    if (pthread_mutex_init(&_state->stateMutex, NULL) != 0) {
        pthread_mutex_destroy(&_state->lifecycleMutex);
        free(_state);
        _state = NULL;
        return nil;
    }
    atomic_init(&_state->initialized, false);
    atomic_init(&_state->recordingInitialized, false);
    atomic_init(&_state->recording, false);
    atomic_init(&_state->playoutInitialized, false);
    atomic_init(&_state->playing, false);
    return self;
}

- (void)dealloc {
    [self terminateDevice];
    if (_state != NULL) {
        pthread_mutex_destroy(&_state->stateMutex);
        pthread_mutex_destroy(&_state->lifecycleMutex);
        free(_state);
        _state = NULL;
    }
}

- (BOOL)deliverInterleavedStereoInt16:(const int16_t *)samples
                           frameCount:(NSUInteger)frameCount {
    if (_state == NULL
        || samples == NULL
        || frameCount == 0
        || frameCount > UINT32_MAX
        || frameCount > UINT32_MAX / (ASAudioChannelCount * sizeof(int16_t))) {
        return NO;
    }

    pthread_mutex_lock(&_state->lifecycleMutex);
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    const BOOL canDeliverLifecycle = delegate != nil
        && atomic_load_explicit(&_state->initialized, memory_order_acquire)
        && atomic_load_explicit(&_state->recordingInitialized, memory_order_acquire)
        && atomic_load_explicit(&_state->recording, memory_order_acquire);
    if (!canDeliverLifecycle) {
        pthread_mutex_lock(&_state->stateMutex);
        _state->receivedFrameCount += frameCount;
        _state->rejectedFrameCount += frameCount;
        pthread_mutex_unlock(&_state->stateMutex);
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }

    pthread_mutex_lock(&_state->stateMutex);
    const BOOL generationIsApproved = _state->recordingGeneration != 0
        && _state->approvedRecordingGeneration == _state->recordingGeneration;
    if (!generationIsApproved) {
        _state->receivedFrameCount += frameCount;
        _state->rejectedFrameCount += frameCount;
        _state->admissionBlockedFrameCount += frameCount;
        pthread_mutex_unlock(&_state->stateMutex);
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }
    pthread_mutex_unlock(&_state->stateMutex);

    const pthread_t currentThread = pthread_self();
    BOOL threadChanged = NO;
    pthread_mutex_lock(&_state->stateMutex);
    if (_state->deliveryThreadIsValid
        && !pthread_equal(_state->deliveryThread, currentThread)) {
        threadChanged = YES;
        _state->deliveryThreadChangeCount += 1;
        _state->inputInterruptionCount += 1;
    }
    _state->deliveryThread = currentThread;
    _state->deliveryThreadIsValid = YES;

    const Float64 sampleTime = _state->nextDeliverySampleTime;
    const uint64_t hostTime = ASStrictlyIncreasingHostTime(_state->lastDeliveryHostTime);
    _state->nextDeliverySampleTime += (Float64)frameCount;
    _state->lastDeliverySampleTime = sampleTime;
    _state->lastDeliveryHostTime = hostTime;
    _state->lastDeliveryFrameCount = (uint32_t)frameCount;
    _state->receivedFrameCount += frameCount;
    _state->deliveryCallbackCount += 1;
    pthread_mutex_unlock(&_state->stateMutex);

    // The delegate contract requires an interruption notification before a different native
    // thread starts calling deliverRecordedData. The application queue is serial, but GCD may
    // legitimately move that logical queue between pthreads over a long session.
    if (threadChanged) {
        ASNotifyInputInterrupted(delegate);
    }

    AudioUnitRenderActionFlags actionFlags = 0;
    AudioTimeStamp timestamp = {0};
    timestamp.mSampleTime = sampleTime;
    timestamp.mHostTime = hostTime;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    const LKRTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData =
        [delegate.deliverRecordedData copy];

    // LiveKitWebRTC 144.7559.11's direct-input bridge constructs FineAudioBuffer's span with
    // `num_frames` elements even for a two-channel interleaved AudioBufferList. FineAudioBuffer
    // counts individual Int16 elements, so that path silently consumes only half the stereo PCM.
    // The public render-block path is correct: the pinned bridge allocates
    // `num_frames * inputNumberOfChannels`, invokes this synchronous block, and forwards the
    // complete native buffer. Keep the truthful per-channel frame count and use that path rather
    // than lying about frameCount or depending on private native state.
    const UInt32 callbackFrameCount = (UInt32)frameCount;
    const UInt32 requiredByteCount =
        callbackFrameCount * ASAudioChannelCount * (UInt32)sizeof(int16_t);
    ASMacStereoRenderContext renderContext = {
        .samples = samples,
        .frameCount = callbackFrameCount,
        .byteCount = requiredByteCount,
    };
    const OSStatus status = deliverRecordedData(
        &actionFlags,
        &timestamp,
        0,
        callbackFrameCount,
        NULL,
        &renderContext,
        ASRenderStereoRecordedData
    );

    const uint64_t requiredSampleElementCount =
        (uint64_t)callbackFrameCount * ASAudioChannelCount;
    const BOOL renderWasAcknowledged = status == noErr
        && renderContext.invocationCount == 1
        && renderContext.copiedFrameCount == callbackFrameCount
        && renderContext.copiedSampleElementCount == requiredSampleElementCount
        && renderContext.validationFailureCount == 0;

    pthread_mutex_lock(&_state->stateMutex);
    _state->renderInvocationCount += renderContext.invocationCount;
    _state->renderCopiedFrameCount += renderContext.copiedFrameCount;
    _state->renderCopiedSampleElementCount += renderContext.copiedSampleElementCount;
    _state->renderValidationFailureCount += renderContext.validationFailureCount;
    if (renderContext.invocationCount == 0) {
        _state->renderNotInvokedCount += 1;
    } else if (renderContext.invocationCount > 1) {
        _state->renderMultipleInvocationCount += 1;
    }
    if (status != noErr) {
        _state->nativeDeliveryErrorCount += 1;
    }
    if (renderWasAcknowledged) {
        _state->deliveredFrameCount += frameCount;
    } else {
        _state->deliveryFailureCount += 1;
        _state->rejectedFrameCount += frameCount;
    }
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return renderWasAcknowledged;
}

- (BOOL)approveCurrentRecordingGeneration {
    if (_state == NULL) {
        return NO;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    const BOOL recording = atomic_load_explicit(
        &_state->recording,
        memory_order_acquire
    );
    pthread_mutex_lock(&_state->stateMutex);
    if (recording && _state->recordingGeneration != 0) {
        _state->approvedRecordingGeneration = _state->recordingGeneration;
    }
    const BOOL approved = recording
        && _state->approvedRecordingGeneration == _state->recordingGeneration;
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return approved;
}

- (void)revokeRecordingAdmission {
    if (_state == NULL) {
        return;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    pthread_mutex_lock(&_state->stateMutex);
    _state->approvedRecordingGeneration = 0;
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
}

- (BOOL)pullHeadlessPlayoutFrames:(NSUInteger)frameCount {
    if (_state == NULL
        || frameCount == 0
        || frameCount > UINT32_MAX
        || frameCount > UINT32_MAX / (ASAudioChannelCount * sizeof(int16_t))) {
        return NO;
    }

    pthread_mutex_lock(&_state->lifecycleMutex);
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    const BOOL canPull = delegate != nil
        && atomic_load_explicit(&_state->initialized, memory_order_acquire)
        && atomic_load_explicit(&_state->playoutInitialized, memory_order_acquire)
        && atomic_load_explicit(&_state->playing, memory_order_acquire);
    if (!canPull) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }

    const pthread_t currentThread = pthread_self();
    BOOL threadChanged = NO;
    pthread_mutex_lock(&_state->stateMutex);
    if (_state->playoutThreadIsValid
        && !pthread_equal(_state->playoutThread, currentThread)) {
        threadChanged = YES;
    }
    _state->playoutThread = currentThread;
    _state->playoutThreadIsValid = YES;
    const Float64 sampleTime = _state->nextPlayoutSampleTime;
    const uint64_t hostTime = ASStrictlyIncreasingHostTime(_state->lastPlayoutHostTime);
    _state->nextPlayoutSampleTime += (Float64)frameCount;
    _state->lastPlayoutHostTime = hostTime;
    pthread_mutex_unlock(&_state->stateMutex);
    if (threadChanged) {
        ASNotifyOutputInterrupted(delegate);
    }

    const size_t sampleCount = frameCount * ASAudioChannelCount;
    int16_t *samples = calloc(sampleCount, sizeof(int16_t));
    if (samples == NULL) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }
    AudioBufferList audioBufferList = {0};
    audioBufferList.mNumberBuffers = 1;
    audioBufferList.mBuffers[0].mNumberChannels = (UInt32)ASAudioChannelCount;
    audioBufferList.mBuffers[0].mDataByteSize = (UInt32)(sampleCount * sizeof(int16_t));
    audioBufferList.mBuffers[0].mData = samples;

    AudioUnitRenderActionFlags actionFlags = 0;
    AudioTimeStamp timestamp = {0};
    timestamp.mSampleTime = sampleTime;
    timestamp.mHostTime = hostTime;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    const LKRTCAudioDeviceGetPlayoutDataBlock getPlayoutData =
        [delegate.getPlayoutData copy];
    const OSStatus status = getPlayoutData(
        &actionFlags,
        &timestamp,
        0,
        (UInt32)frameCount,
        &audioBufferList
    );
    free(samples);

    pthread_mutex_lock(&_state->stateMutex);
    _state->playoutCallbackCount += 1;
    if (status == noErr) {
        _state->playoutFrameCount += frameCount;
    } else {
        _state->playoutFailureCount += 1;
    }
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return status == noErr;
}

- (ASMacStereoAudioDeviceDiagnostics)diagnostics {
    ASMacStereoAudioDeviceDiagnostics diagnostics = {0};
    if (_state == NULL) {
        return diagnostics;
    }
    diagnostics.initialized = atomic_load_explicit(&_state->initialized, memory_order_acquire);
    diagnostics.recordingInitialized = atomic_load_explicit(
        &_state->recordingInitialized,
        memory_order_acquire
    );
    diagnostics.recording = atomic_load_explicit(&_state->recording, memory_order_acquire);
    diagnostics.playoutInitialized = atomic_load_explicit(
        &_state->playoutInitialized,
        memory_order_acquire
    );
    diagnostics.playing = atomic_load_explicit(&_state->playing, memory_order_acquire);

    pthread_mutex_lock(&_state->stateMutex);
    diagnostics.receivedFrameCount = _state->receivedFrameCount;
    diagnostics.deliveredFrameCount = _state->deliveredFrameCount;
    diagnostics.rejectedFrameCount = _state->rejectedFrameCount;
    diagnostics.deliveryCallbackCount = _state->deliveryCallbackCount;
    diagnostics.deliveryFailureCount = _state->deliveryFailureCount;
    diagnostics.nativeDeliveryErrorCount = _state->nativeDeliveryErrorCount;
    diagnostics.renderInvocationCount = _state->renderInvocationCount;
    diagnostics.renderCopiedFrameCount = _state->renderCopiedFrameCount;
    diagnostics.renderCopiedSampleElementCount = _state->renderCopiedSampleElementCount;
    diagnostics.renderNotInvokedCount = _state->renderNotInvokedCount;
    diagnostics.renderMultipleInvocationCount = _state->renderMultipleInvocationCount;
    diagnostics.renderValidationFailureCount = _state->renderValidationFailureCount;
    diagnostics.prefilledInputDataDeliveryCount = _state->prefilledInputDataDeliveryCount;
    diagnostics.timestampResetCount = _state->timestampResetCount;
    diagnostics.recordingGeneration = _state->recordingGeneration;
    diagnostics.approvedRecordingGeneration = _state->approvedRecordingGeneration;
    diagnostics.admissionBlockedFrameCount = _state->admissionBlockedFrameCount;
    diagnostics.inputInterruptionCount = _state->inputInterruptionCount;
    diagnostics.deliveryThreadChangeCount = _state->deliveryThreadChangeCount;
    diagnostics.lastDeliveryFrameCount = _state->lastDeliveryFrameCount;
    diagnostics.lastDeliverySampleTime = _state->lastDeliverySampleTime;
    diagnostics.lastDeliveryHostTime = _state->lastDeliveryHostTime;
    diagnostics.playoutCallbackCount = _state->playoutCallbackCount;
    diagnostics.playoutFrameCount = _state->playoutFrameCount;
    diagnostics.playoutFailureCount = _state->playoutFailureCount;
    pthread_mutex_unlock(&_state->stateMutex);
    return diagnostics;
}

#pragma mark - LKRTCAudioDevice fixed format

- (double)deviceInputSampleRate { return ASAudioSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return ASAudioIOBufferDuration; }
- (NSInteger)inputNumberOfChannels { return ASAudioChannelCount; }
- (NSTimeInterval)inputLatency { return 0; }
- (double)deviceOutputSampleRate { return ASAudioSampleRate; }
- (NSTimeInterval)outputIOBufferDuration { return ASAudioIOBufferDuration; }
- (NSInteger)outputNumberOfChannels { return ASAudioChannelCount; }
- (NSTimeInterval)outputLatency { return 0; }

- (BOOL)isInitialized {
    return _state != NULL
        && atomic_load_explicit(&_state->initialized, memory_order_acquire);
}

- (BOOL)initializeWithDelegate:(id<LKRTCAudioDeviceDelegate>)delegate {
    if (_state == NULL || delegate == nil) {
        return NO;
    }
    if (self.isInitialized) {
        return self.delegate == delegate;
    }
    self.delegate = delegate;
    atomic_store_explicit(&_state->initialized, true, memory_order_release);
    return YES;
}

- (BOOL)terminateDevice {
    if (_state == NULL) {
        return YES;
    }
    [self stopRecording];
    [self stopPlayout];
    atomic_store_explicit(&_state->recordingInitialized, false, memory_order_release);
    atomic_store_explicit(&_state->playoutInitialized, false, memory_order_release);
    atomic_store_explicit(&_state->initialized, false, memory_order_release);
    self.delegate = nil;
    return YES;
}

- (BOOL)isPlayoutInitialized {
    return _state != NULL
        && atomic_load_explicit(&_state->playoutInitialized, memory_order_acquire);
}

- (BOOL)initializePlayout {
    if (!self.isInitialized) {
        return NO;
    }
    atomic_store_explicit(&_state->playoutInitialized, true, memory_order_release);
    return YES;
}

- (BOOL)isPlaying {
    return _state != NULL
        && atomic_load_explicit(&_state->playing, memory_order_acquire);
}

- (BOOL)startPlayout {
    if (_state == NULL) {
        return NO;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    if (!atomic_load_explicit(&_state->initialized, memory_order_acquire)
        || !atomic_load_explicit(&_state->playoutInitialized, memory_order_acquire)) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }
    if (atomic_load_explicit(&_state->playing, memory_order_acquire)) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return YES;
    }
    pthread_mutex_lock(&_state->stateMutex);
    _state->nextPlayoutSampleTime = 0;
    _state->lastPlayoutHostTime = 0;
    _state->playoutThreadIsValid = NO;
    pthread_mutex_unlock(&_state->stateMutex);
    atomic_store_explicit(&_state->playing, true, memory_order_release);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return YES;
}

- (BOOL)stopPlayout {
    if (_state == NULL) {
        return YES;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    const BOOL wasPlaying = atomic_exchange_explicit(
        &_state->playing,
        false,
        memory_order_acq_rel
    );
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (wasPlaying && delegate != nil) {
        ASNotifyOutputInterrupted(delegate);
    }
    pthread_mutex_lock(&_state->stateMutex);
    _state->playoutThreadIsValid = NO;
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return YES;
}

- (BOOL)isRecordingInitialized {
    return _state != NULL
        && atomic_load_explicit(&_state->recordingInitialized, memory_order_acquire);
}

- (BOOL)initializeRecording {
    if (!self.isInitialized) {
        return NO;
    }
    atomic_store_explicit(&_state->recordingInitialized, true, memory_order_release);
    return YES;
}

- (BOOL)isRecording {
    return _state != NULL
        && atomic_load_explicit(&_state->recording, memory_order_acquire);
}

- (BOOL)startRecording {
    if (_state == NULL) {
        return NO;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    if (!atomic_load_explicit(&_state->initialized, memory_order_acquire)
        || !atomic_load_explicit(&_state->recordingInitialized, memory_order_acquire)) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return NO;
    }
    // Native WebRTC can repeat StartRecording while the same stream is already active. Treat
    // that as an idempotent protocol call: resetting timestamps or advancing the admission
    // generation here would create an artificial discontinuity and unexpectedly fail closed.
    if (atomic_load_explicit(&_state->recording, memory_order_acquire)) {
        pthread_mutex_unlock(&_state->lifecycleMutex);
        return YES;
    }
    pthread_mutex_lock(&_state->stateMutex);
    _state->nextDeliverySampleTime = 0;
    _state->lastDeliverySampleTime = 0;
    _state->lastDeliveryHostTime = 0;
    _state->lastDeliveryFrameCount = 0;
    _state->deliveryThreadIsValid = NO;
    _state->recordingGeneration += 1;
    if (_state->recordingGeneration == 0) {
        _state->recordingGeneration = 1;
    }
    _state->approvedRecordingGeneration = 0;
    _state->timestampResetCount += 1;
    pthread_mutex_unlock(&_state->stateMutex);
    atomic_store_explicit(&_state->recording, true, memory_order_release);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return YES;
}

- (BOOL)stopRecording {
    if (_state == NULL) {
        return YES;
    }
    pthread_mutex_lock(&_state->lifecycleMutex);
    const BOOL wasRecording = atomic_exchange_explicit(
        &_state->recording,
        false,
        memory_order_acq_rel
    );
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (wasRecording && delegate != nil) {
        pthread_mutex_lock(&_state->stateMutex);
        _state->inputInterruptionCount += 1;
        pthread_mutex_unlock(&_state->stateMutex);
        ASNotifyInputInterrupted(delegate);
    }
    pthread_mutex_lock(&_state->stateMutex);
    _state->deliveryThreadIsValid = NO;
    _state->approvedRecordingGeneration = 0;
    pthread_mutex_unlock(&_state->stateMutex);
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return YES;
}

@end

BOOL ASMacWebRTCAudioDevicePreflight(NSError **error) {
    Class factoryClass = NSClassFromString(@"LKRTCPeerConnectionFactory");
    if (factoryClass == Nil) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorFactoryClassMissing,
                @"The pinned LKRTCPeerConnectionFactory class is unavailable."
            );
        }
        return NO;
    }

    SEL selector = NSSelectorFromString(@"initWithEncoderFactory:decoderFactory:audioDevice:");
    Method method = class_getInstanceMethod(factoryClass, selector);
    if (method == NULL) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorFactorySelectorMissing,
                @"The pinned custom-audio-device factory selector is unavailable."
            );
        }
        return NO;
    }
    const char *typeEncoding = method_getTypeEncoding(method);
    static const char *expectedTypeEncoding = "@40@0:8@16@24@32";
    if (typeEncoding == NULL || strcmp(typeEncoding, expectedTypeEncoding) != 0) {
        if (error != NULL) {
            NSString *actual = typeEncoding == NULL
                ? @"(null)"
                : [NSString stringWithUTF8String:typeEncoding];
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorFactorySelectorABIMismatch,
                [NSString stringWithFormat:
                    @"The custom-audio-device factory ABI changed (expected %s, found %@).",
                    expectedTypeEncoding,
                    actual]
            );
        }
        return NO;
    }

    if (NSProtocolFromString(@"LKRTCAudioDeviceDelegate") == nil) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorDelegateProtocolMissing,
                @"The pinned custom audio-device delegate protocol is unavailable."
            );
        }
        return NO;
    }
    Class delegateBridgeClass = NSClassFromString(@"LKRTCObjCAudioDeviceDelegate");
    if (delegateBridgeClass == Nil) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorDelegateBridgeClassMissing,
                @"The pinned custom audio-device delegate bridge is unavailable."
            );
        }
        return NO;
    }
    if (!ASMethodHasTypeEncoding(
            delegateBridgeClass,
            NSSelectorFromString(@"deliverRecordedData"),
            "@?16@0:8"
        )
        || !ASMethodHasTypeEncoding(
            delegateBridgeClass,
            NSSelectorFromString(@"preferredInputSampleRate"),
            "d16@0:8"
        )
        || !ASMethodHasTypeEncoding(
            delegateBridgeClass,
            NSSelectorFromString(@"dispatchSync:"),
            "v24@0:8@?16"
        )) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorDelegateBridgeABIMismatch,
                @"The pinned custom audio-device delegate bridge ABI changed."
            );
        }
        return NO;
    }
    if (error != NULL) {
        *error = nil;
    }
    return YES;
}

LKRTCPeerConnectionFactory *ASCreateMacStereoPeerConnectionFactory(
    id<LKRTCVideoEncoderFactory> encoderFactory,
    id<LKRTCVideoDecoderFactory> decoderFactory,
    ASMacStereoAudioDevice *audioDevice,
    NSError **error
) {
    if (audioDevice == nil) {
        if (error != NULL) {
            *error = ASPreflightError(
                ASMacWebRTCAudioDeviceErrorFactoryCreationFailed,
                @"A nonnull custom stereo audio device is required."
            );
        }
        return nil;
    }
    if (!ASMacWebRTCAudioDevicePreflight(error)) {
        return nil;
    }
    LKRTCPeerConnectionFactory *factory = [[LKRTCPeerConnectionFactory alloc]
        initWithEncoderFactory:encoderFactory
        decoderFactory:decoderFactory
        audioDevice:audioDevice];
    if (factory == nil && error != NULL) {
        *error = ASPreflightError(
            ASMacWebRTCAudioDeviceErrorFactoryCreationFailed,
            @"LiveKitWebRTC rejected the custom stereo audio device."
        );
    }
    return factory;
}
