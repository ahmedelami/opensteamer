#import "RTCAudioDeviceCompat.h"
#import "MacWebRTCAudioDeviceShim.h"

#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <sched.h>
#import <stdatomic.h>
#import <string.h>

// This file is the intentionally narrow ABI bridge between source-clock stereo PCM and the
// exact-pinned native WebRTC audio device. Lifecycle locks never enter WebRTC's render callback;
// diagnostics use a separate lock so observation cannot change audio admission semantics.
NSErrorDomain const ASMacWebRTCAudioDeviceErrorDomain = @"opensteamer.MacWebRTCAudioDevice";

static const double ASAudioSampleRate = 48000.0;
static const NSTimeInterval ASAudioIOBufferDuration = 0.010;
enum { ASAudioChannelCount = 2 };
static const uint_fast64_t ASMacPlayoutPullClosedBit =
    ((uint_fast64_t)1 << 63);
static const uint_fast64_t ASMacPlayoutPullCountMask =
    ASMacPlayoutPullClosedBit - 1;

_Static_assert(
    ATOMIC_LONG_LOCK_FREE == 2,
    "Mac realtime lifetime atomics must be lock-free"
);

_Static_assert(
    ATOMIC_BOOL_LOCK_FREE == 2,
    "Mac realtime progress booleans must be lock-free"
);
_Static_assert(
    ATOMIC_INT_LOCK_FREE == 2,
    "Mac realtime progress status atomics must be lock-free"
);

static const uint_fast64_t ASMacAudioQueueCallbackClosedBit =
    ((uint_fast64_t)1 << 63);
static const uint_fast64_t ASMacAudioQueueCallbackCountMask =
    ASMacAudioQueueCallbackClosedBit - 1;

typedef struct ASMacAudioQueueCallbackLifetimeStorage {
    atomic_uint_fast64_t state;
} ASMacAudioQueueCallbackLifetimeStorage;

ASMacAudioQueueCallbackLifetimeRef
ASMacAudioQueueCallbackLifetimeCreate(void) {
    ASMacAudioQueueCallbackLifetimeStorage *storage =
        calloc(1, sizeof(ASMacAudioQueueCallbackLifetimeStorage));
    if (storage == NULL) {
        return NULL;
    }

    atomic_init(&storage->state, 0);
    return storage;
}

void ASMacAudioQueueCallbackLifetimeDestroy(
    ASMacAudioQueueCallbackLifetimeRef lifetime
) {
    if (lifetime == NULL) {
        return;
    }

    free((ASMacAudioQueueCallbackLifetimeStorage *)lifetime);
}

bool ASMacAudioQueueCallbackLifetimeTryEnter(
    ASMacAudioQueueCallbackLifetimeRef lifetime
) {
    if (lifetime == NULL) {
        return false;
    }

    ASMacAudioQueueCallbackLifetimeStorage *storage =
        (ASMacAudioQueueCallbackLifetimeStorage *)lifetime;
    uint_fast64_t observed = atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    );

    for (;;) {
        if ((observed & ASMacAudioQueueCallbackClosedBit) != 0
            || (observed & ASMacAudioQueueCallbackCountMask)
                == ASMacAudioQueueCallbackCountMask) {
            return false;
        }

        if (atomic_compare_exchange_weak_explicit(
                &storage->state,
                &observed,
                observed + 1,
                memory_order_acq_rel,
                memory_order_acquire
            )) {
            return true;
        }
    }
}

void ASMacAudioQueueCallbackLifetimeLeave(
    ASMacAudioQueueCallbackLifetimeRef lifetime
) {
    if (lifetime == NULL) {
        return;
    }

    ASMacAudioQueueCallbackLifetimeStorage *storage =
        (ASMacAudioQueueCallbackLifetimeStorage *)lifetime;
    atomic_fetch_sub_explicit(
        &storage->state,
        1,
        memory_order_release
    );
}

void ASMacAudioQueueCallbackLifetimeClose(
    ASMacAudioQueueCallbackLifetimeRef lifetime
) {
    if (lifetime == NULL) {
        return;
    }

    ASMacAudioQueueCallbackLifetimeStorage *storage =
        (ASMacAudioQueueCallbackLifetimeStorage *)lifetime;
    atomic_fetch_or_explicit(
        &storage->state,
        ASMacAudioQueueCallbackClosedBit,
        memory_order_acq_rel
    );
}

void ASMacAudioQueueCallbackLifetimeWaitForCallbacks(
    ASMacAudioQueueCallbackLifetimeRef lifetime
) {
    if (lifetime == NULL) {
        return;
    }

    ASMacAudioQueueCallbackLifetimeStorage *storage =
        (ASMacAudioQueueCallbackLifetimeStorage *)lifetime;
    while ((atomic_load_explicit(
                &storage->state,
                memory_order_acquire
            ) & ASMacAudioQueueCallbackCountMask) != 0) {
        sched_yield();
    }
}

static const uint_fast64_t ASMacAudioQueueFailurePresentBit =
    ((uint_fast64_t)1 << 63);
static const uint_fast64_t ASMacAudioQueueFailureReportedBit =
    ((uint_fast64_t)1 << 62);
static const uint_fast64_t ASMacAudioQueueFailureStatusMask =
    UINT32_MAX;

typedef struct ASMacAudioQueueRuntimeFailureLatchStorage {
    atomic_uint_fast64_t state;
} ASMacAudioQueueRuntimeFailureLatchStorage;

ASMacAudioQueueRuntimeFailureLatchRef
ASMacAudioQueueRuntimeFailureLatchCreate(void) {
    ASMacAudioQueueRuntimeFailureLatchStorage *storage =
        calloc(1, sizeof(ASMacAudioQueueRuntimeFailureLatchStorage));
    if (storage == NULL) {
        return NULL;
    }

    atomic_init(&storage->state, 0);
    return storage;
}

void ASMacAudioQueueRuntimeFailureLatchDestroy(
    ASMacAudioQueueRuntimeFailureLatchRef latch
) {
    if (latch == NULL) {
        return;
    }

    free((ASMacAudioQueueRuntimeFailureLatchStorage *)latch);
}

void ASMacAudioQueueRuntimeFailureLatchReset(
    ASMacAudioQueueRuntimeFailureLatchRef latch
) {
    if (latch == NULL) {
        return;
    }

    ASMacAudioQueueRuntimeFailureLatchStorage *storage =
        (ASMacAudioQueueRuntimeFailureLatchStorage *)latch;
    atomic_store_explicit(&storage->state, 0, memory_order_release);
}

void ASMacAudioQueueRuntimeFailureLatchPublish(
    ASMacAudioQueueRuntimeFailureLatchRef latch,
    int32_t status
) {
    if (latch == NULL || status == noErr) {
        return;
    }

    uint32_t statusBits = 0;
    memcpy(&statusBits, &status, sizeof(statusBits));

    ASMacAudioQueueRuntimeFailureLatchStorage *storage =
        (ASMacAudioQueueRuntimeFailureLatchStorage *)latch;
    uint_fast64_t expected = 0;
    const uint_fast64_t desired =
        ASMacAudioQueueFailurePresentBit | statusBits;
    (void)atomic_compare_exchange_strong_explicit(
        &storage->state,
        &expected,
        desired,
        memory_order_release,
        memory_order_relaxed
    );
}

bool ASMacAudioQueueRuntimeFailureLatchTake(
    ASMacAudioQueueRuntimeFailureLatchRef latch,
    int32_t *status
) {
    if (latch == NULL || status == NULL) {
        return false;
    }

    ASMacAudioQueueRuntimeFailureLatchStorage *storage =
        (ASMacAudioQueueRuntimeFailureLatchStorage *)latch;
    uint_fast64_t observed = atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    );

    for (;;) {
        if ((observed & ASMacAudioQueueFailurePresentBit) == 0
            || (observed & ASMacAudioQueueFailureReportedBit) != 0) {
            return false;
        }

        const uint_fast64_t desired =
            observed | ASMacAudioQueueFailureReportedBit;
        if (atomic_compare_exchange_weak_explicit(
                &storage->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire
            )) {
            const uint32_t statusBits =
                (uint32_t)(observed & ASMacAudioQueueFailureStatusMask);
            memcpy(status, &statusBits, sizeof(*status));
            return true;
        }
    }
}

typedef struct ASMacAudioQueueProgressStorage {
    atomic_bool queueRunning;
    atomic_uint_fast64_t postStartCallbackCount;
    atomic_uint_fast64_t requestedFrameCount;
    atomic_uint_fast64_t successfulPullCount;
    atomic_uint_fast64_t successfulFrameCount;
    atomic_uint_fast64_t silenceFallbackCount;
    atomic_uint_fast64_t silenceFrameCount;
    atomic_uint_fast64_t enqueueFailureCount;
    atomic_int_least32_t lastEnqueueStatus;
} ASMacAudioQueueProgressStorage;

ASMacAudioQueueProgressRef
ASMacAudioQueueProgressCreate(void) {
    ASMacAudioQueueProgressStorage *storage =
        calloc(1, sizeof(ASMacAudioQueueProgressStorage));
    if (storage == NULL) {
        return NULL;
    }

    atomic_init(&storage->queueRunning, false);
    atomic_init(&storage->postStartCallbackCount, 0);
    atomic_init(&storage->requestedFrameCount, 0);
    atomic_init(&storage->successfulPullCount, 0);
    atomic_init(&storage->successfulFrameCount, 0);
    atomic_init(&storage->silenceFallbackCount, 0);
    atomic_init(&storage->silenceFrameCount, 0);
    atomic_init(&storage->enqueueFailureCount, 0);
    atomic_init(&storage->lastEnqueueStatus, noErr);
    return storage;
}

void ASMacAudioQueueProgressDestroy(
    ASMacAudioQueueProgressRef progress
) {
    if (progress == NULL) {
        return;
    }

    free((ASMacAudioQueueProgressStorage *)progress);
}

void ASMacAudioQueueProgressReset(
    ASMacAudioQueueProgressRef progress
) {
    if (progress == NULL) {
        return;
    }

    ASMacAudioQueueProgressStorage *storage =
        (ASMacAudioQueueProgressStorage *)progress;
    atomic_store_explicit(
        &storage->queueRunning,
        false,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->postStartCallbackCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->requestedFrameCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->successfulPullCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->successfulFrameCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->silenceFallbackCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->silenceFrameCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->enqueueFailureCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &storage->lastEnqueueStatus,
        noErr,
        memory_order_seq_cst
    );
}

void ASMacAudioQueueProgressSetQueueRunning(
    ASMacAudioQueueProgressRef progress,
    bool queueRunning
) {
    if (progress == NULL) {
        return;
    }

    ASMacAudioQueueProgressStorage *storage =
        (ASMacAudioQueueProgressStorage *)progress;
    atomic_store_explicit(
        &storage->queueRunning,
        queueRunning,
        memory_order_seq_cst
    );
}

void ASMacAudioQueueProgressPublish(
    ASMacAudioQueueProgressRef progress,
    uint64_t requestedFrameCount,
    bool pullSucceeded,
    int32_t enqueueStatus
) {
    if (progress == NULL) {
        return;
    }

    ASMacAudioQueueProgressStorage *storage =
        (ASMacAudioQueueProgressStorage *)progress;
    if (!atomic_load_explicit(
            &storage->queueRunning,
            memory_order_seq_cst
        )) {
        return;
    }

    atomic_fetch_add_explicit(
        &storage->postStartCallbackCount,
        1,
        memory_order_seq_cst
    );
    atomic_fetch_add_explicit(
        &storage->requestedFrameCount,
        requestedFrameCount,
        memory_order_seq_cst
    );

    if (pullSucceeded) {
        atomic_fetch_add_explicit(
            &storage->successfulPullCount,
            1,
            memory_order_seq_cst
        );
        atomic_fetch_add_explicit(
            &storage->successfulFrameCount,
            requestedFrameCount,
            memory_order_seq_cst
        );
    } else {
        atomic_fetch_add_explicit(
            &storage->silenceFallbackCount,
            1,
            memory_order_seq_cst
        );
        atomic_fetch_add_explicit(
            &storage->silenceFrameCount,
            requestedFrameCount,
            memory_order_seq_cst
        );
    }

    atomic_store_explicit(
        &storage->lastEnqueueStatus,
        enqueueStatus,
        memory_order_seq_cst
    );
    if (enqueueStatus != noErr) {
        atomic_fetch_add_explicit(
            &storage->enqueueFailureCount,
            1,
            memory_order_seq_cst
        );
    }
}

ASMacAudioQueueProgressSnapshot
ASMacAudioQueueProgressRead(
    ASMacAudioQueueProgressRef progress
) {
    ASMacAudioQueueProgressSnapshot snapshot = {0};
    if (progress == NULL) {
        return snapshot;
    }

    ASMacAudioQueueProgressStorage *storage =
        (ASMacAudioQueueProgressStorage *)progress;
    snapshot.queueRunning = atomic_load_explicit(
        &storage->queueRunning,
        memory_order_seq_cst
    );
    snapshot.postStartCallbackCount = atomic_load_explicit(
        &storage->postStartCallbackCount,
        memory_order_seq_cst
    );
    snapshot.requestedFrameCount = atomic_load_explicit(
        &storage->requestedFrameCount,
        memory_order_seq_cst
    );
    snapshot.successfulPullCount = atomic_load_explicit(
        &storage->successfulPullCount,
        memory_order_seq_cst
    );
    snapshot.successfulFrameCount = atomic_load_explicit(
        &storage->successfulFrameCount,
        memory_order_seq_cst
    );
    snapshot.silenceFallbackCount = atomic_load_explicit(
        &storage->silenceFallbackCount,
        memory_order_seq_cst
    );
    snapshot.silenceFrameCount = atomic_load_explicit(
        &storage->silenceFrameCount,
        memory_order_seq_cst
    );
    snapshot.enqueueFailureCount = atomic_load_explicit(
        &storage->enqueueFailureCount,
        memory_order_seq_cst
    );
    snapshot.lastEnqueueStatus = atomic_load_explicit(
        &storage->lastEnqueueStatus,
        memory_order_seq_cst
    );
    return snapshot;
}

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
    atomic_uint_fast64_t playoutPullState;
    atomic_uint_fast64_t playoutFenceWaitCount;
    #if DEBUG
    atomic_bool holdPlayoutPullsForTesting;
    atomic_bool playoutPullIsHeldForTesting;
    #endif

    pthread_t deliveryThread;
    BOOL deliveryThreadIsValid;
    pthread_t playoutThread;
    BOOL playoutThreadIsValid;

    Float64 nextDeliverySampleTime;
    uint64_t lastDeliveryHostTime;
    atomic_uint_fast64_t nextPlayoutFrame;
    atomic_uint_fast64_t lastPlayoutHostTime;

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
    atomic_uint_fast64_t playoutCallbackCount;
    atomic_uint_fast64_t playoutFrameCount;
    atomic_uint_fast64_t playoutFailureCount;
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

static uint64_t ASNextAtomicHostTime(atomic_uint_fast64_t *storage) {
    uint_fast64_t observed = atomic_load_explicit(storage, memory_order_relaxed);
    for (;;) {
        const uint64_t now = mach_absolute_time();
        uint_fast64_t candidate = now > observed ? now : observed + 1;
        if (atomic_compare_exchange_weak_explicit(
                storage,
                &observed,
                candidate,
                memory_order_relaxed,
                memory_order_relaxed
            )) {
            return candidate;
        }
    }
}

static BOOL ASBeginMacPlayoutPull(ASMacStereoAudioDeviceState *state) {
    uint_fast64_t observed = atomic_load_explicit(
        &state->playoutPullState,
        memory_order_acquire
    );
    for (;;) {
        if ((observed & ASMacPlayoutPullClosedBit) != 0
            || (observed & ASMacPlayoutPullCountMask)
                == ASMacPlayoutPullCountMask) {
            return NO;
        }
        if (atomic_compare_exchange_weak_explicit(
                &state->playoutPullState,
                &observed,
                observed + 1,
                memory_order_acq_rel,
                memory_order_acquire
            )) {
            return YES;
        }
    }
}

static void ASEndMacPlayoutPull(ASMacStereoAudioDeviceState *state) {
    atomic_fetch_sub_explicit(
        &state->playoutPullState,
        1,
        memory_order_release
    );
}

static void ASCloseAndFenceMacPlayoutPulls(
    ASMacStereoAudioDeviceState *state
) {
    const uint_fast64_t previous = atomic_fetch_or_explicit(
        &state->playoutPullState,
        ASMacPlayoutPullClosedBit,
        memory_order_acq_rel
    );
    if ((previous & ASMacPlayoutPullCountMask) != 0) {
        atomic_fetch_add_explicit(
            &state->playoutFenceWaitCount,
            1,
            memory_order_relaxed
        );
    }
    while ((atomic_load_explicit(
                &state->playoutPullState,
                memory_order_acquire
            ) & ASMacPlayoutPullCountMask) != 0) {
        sched_yield();
    }
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
    LKRTCAudioDeviceGetPlayoutDataBlock _playoutBlock;
    id<LKRTCAudioDeviceDelegate> _playoutDelegateOwner;
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
    atomic_init(
        &_state->playoutPullState,
        ASMacPlayoutPullClosedBit
    );
    atomic_init(&_state->playoutFenceWaitCount, 0);
    #if DEBUG
    atomic_init(&_state->holdPlayoutPullsForTesting, false);
    atomic_init(&_state->playoutPullIsHeldForTesting, false);
    #endif
    atomic_init(&_state->nextPlayoutFrame, 0);
    atomic_init(&_state->lastPlayoutHostTime, 0);
    atomic_init(&_state->playoutCallbackCount, 0);
    atomic_init(&_state->playoutFrameCount, 0);
    atomic_init(&_state->playoutFailureCount, 0);
    return self;
}

- (void)dealloc {
    [self terminateDevice];
    _playoutBlock = nil;
    _playoutDelegateOwner = nil;
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

- (BOOL)approveRecordingGeneration:(uint64_t)recordingGeneration {
    if (_state == NULL || recordingGeneration == 0) {
        return NO;
    }

    pthread_mutex_lock(&_state->lifecycleMutex);
    const BOOL recording = atomic_load_explicit(
        &_state->recording,
        memory_order_acquire
    );

    pthread_mutex_lock(&_state->stateMutex);
    const BOOL exactGeneration = recording
        && _state->recordingGeneration == recordingGeneration;
    if (exactGeneration) {
        _state->approvedRecordingGeneration = recordingGeneration;
    }
    const BOOL approved = exactGeneration
        && _state->approvedRecordingGeneration
            == _state->recordingGeneration;
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

- (BOOL)renderPlayoutInterleavedStereoInt16:(int16_t *)samples
                                  frameCount:(NSUInteger)frameCount {
    if (_state == NULL
        || samples == NULL
        || frameCount == 0
        || frameCount > UINT32_MAX
        || frameCount > UINT32_MAX / (ASAudioChannelCount * sizeof(int16_t))) {
        return NO;
    }

    const size_t sampleCount = frameCount * ASAudioChannelCount;
    const UInt32 byteCount = (UInt32)(sampleCount * sizeof(int16_t));
    memset(samples, 0, byteCount);

    if (!ASBeginMacPlayoutPull(_state)) {
        return NO;
    }

    #if DEBUG
    if (atomic_load_explicit(
            &_state->holdPlayoutPullsForTesting,
            memory_order_acquire
        )) {
        atomic_store_explicit(
            &_state->playoutPullIsHeldForTesting,
            true,
            memory_order_release
        );
        while (atomic_load_explicit(
            &_state->holdPlayoutPullsForTesting,
            memory_order_acquire
        )) {
            sched_yield();
        }
        atomic_store_explicit(
            &_state->playoutPullIsHeldForTesting,
            false,
            memory_order_release
        );
    }
    #endif

    LKRTCAudioDeviceGetPlayoutDataBlock __unsafe_unretained
        getPlayoutData = _playoutBlock;
    const BOOL canPull = getPlayoutData != nil
        && atomic_load_explicit(&_state->initialized, memory_order_acquire)
        && atomic_load_explicit(&_state->playoutInitialized, memory_order_acquire)
        && atomic_load_explicit(&_state->playing, memory_order_acquire);
    if (!canPull) {
        ASEndMacPlayoutPull(_state);
        return NO;
    }

    const uint64_t firstFrame = atomic_fetch_add_explicit(
        &_state->nextPlayoutFrame,
        frameCount,
        memory_order_relaxed
    );
    const uint64_t hostTime = ASNextAtomicHostTime(
        &_state->lastPlayoutHostTime
    );

    AudioBufferList audioBufferList = {0};
    audioBufferList.mNumberBuffers = 1;
    audioBufferList.mBuffers[0].mNumberChannels = ASAudioChannelCount;
    audioBufferList.mBuffers[0].mDataByteSize = byteCount;
    audioBufferList.mBuffers[0].mData = samples;

    AudioUnitRenderActionFlags actionFlags = 0;
    AudioTimeStamp timestamp = {0};
    timestamp.mSampleTime = (Float64)firstFrame;
    timestamp.mHostTime = hostTime;
    timestamp.mFlags =
        kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    const OSStatus status = getPlayoutData(
        &actionFlags,
        &timestamp,
        0,
        (UInt32)frameCount,
        &audioBufferList
    );

    atomic_fetch_add_explicit(
        &_state->playoutCallbackCount,
        1,
        memory_order_relaxed
    );
    if (status == noErr) {
        atomic_fetch_add_explicit(
            &_state->playoutFrameCount,
            frameCount,
            memory_order_relaxed
        );
        ASEndMacPlayoutPull(_state);
        return YES;
    }
    memset(samples, 0, byteCount);
    atomic_fetch_add_explicit(
        &_state->playoutFailureCount,
        1,
        memory_order_relaxed
    );
    ASEndMacPlayoutPull(_state);
    return NO;
}

- (BOOL)pullHeadlessPlayoutFrames:(NSUInteger)frameCount {
    if (_state == NULL
        || frameCount == 0
        || frameCount > UINT32_MAX
        || frameCount > UINT32_MAX / (ASAudioChannelCount * sizeof(int16_t))) {
        return NO;
    }
    const size_t sampleCount = frameCount * ASAudioChannelCount;
    int16_t *samples = calloc(sampleCount, sizeof(int16_t));
    if (samples == NULL) {
        return NO;
    }
    const BOOL rendered = [self renderPlayoutInterleavedStereoInt16:samples
                                                         frameCount:frameCount];
    free(samples);
    return rendered;
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
    pthread_mutex_unlock(&_state->stateMutex);
    diagnostics.playoutCallbackCount = atomic_load_explicit(
        &_state->playoutCallbackCount,
        memory_order_relaxed
    );
    diagnostics.playoutFrameCount = atomic_load_explicit(
        &_state->playoutFrameCount,
        memory_order_relaxed
    );
    diagnostics.playoutFailureCount = atomic_load_explicit(
        &_state->playoutFailureCount,
        memory_order_relaxed
    );
    const uint_fast64_t pullState = atomic_load_explicit(
        &_state->playoutPullState,
        memory_order_acquire
    );
    diagnostics.playoutPullsInFlight =
        pullState & ASMacPlayoutPullCountMask;
    diagnostics.playoutFenceWaitCount = atomic_load_explicit(
        &_state->playoutFenceWaitCount,
        memory_order_relaxed
    );
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
    if (_playoutDelegateOwner != nil
        && _playoutDelegateOwner != delegate) {
        return NO;
    }
    if (_playoutBlock == nil) {
        LKRTCAudioDeviceGetPlayoutDataBlock playoutBlock =
            [delegate.getPlayoutData copy];
        if (playoutBlock == nil) {
            return NO;
        }
        _playoutBlock = playoutBlock;
        _playoutDelegateOwner = delegate;
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
    atomic_store_explicit(&_state->nextPlayoutFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&_state->lastPlayoutHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&_state->playing, true, memory_order_release);
    atomic_store_explicit(
        &_state->playoutPullState,
        0,
        memory_order_release
    );
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
    ASCloseAndFenceMacPlayoutPulls(_state);
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (wasPlaying && delegate != nil) {
        ASNotifyOutputInterrupted(delegate);
    }
    pthread_mutex_unlock(&_state->lifecycleMutex);
    return YES;
}

#if DEBUG
- (void)holdPlayoutPullsForTesting {
    if (_state == NULL) {
        return;
    }
    atomic_store_explicit(
        &_state->holdPlayoutPullsForTesting,
        true,
        memory_order_release
    );
}

- (void)releasePlayoutPullsForTesting {
    if (_state == NULL) {
        return;
    }
    atomic_store_explicit(
        &_state->holdPlayoutPullsForTesting,
        false,
        memory_order_release
    );
}

- (BOOL)playoutPullIsHeldForTesting {
    return _state != NULL
        && atomic_load_explicit(
            &_state->playoutPullIsHeldForTesting,
            memory_order_acquire
        );
}

- (BOOL)stopPlayoutAndFenceForTesting {
    return [self stopPlayout];
}
#endif

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
