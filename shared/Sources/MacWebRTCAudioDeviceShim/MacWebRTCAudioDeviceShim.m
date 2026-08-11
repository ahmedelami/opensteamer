#import "RTCAudioDeviceCompat.h"
#import "MacWebRTCAudioDeviceShim.h"

#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <math.h>
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

static const uint_fast64_t ASMacAudioQueueWriterAuthorizationOpenBit = 1;

typedef struct ASMacAudioQueueWriterAuthorizationGateStorage {
    /// Bit zero is open/closed; upper bits are the revocation generation.
    atomic_uint_fast64_t state;
} ASMacAudioQueueWriterAuthorizationGateStorage;

ASMacAudioQueueWriterAuthorizationGateRef
ASMacAudioQueueWriterAuthorizationGateCreate(void) {
    ASMacAudioQueueWriterAuthorizationGateStorage *storage =
        calloc(
            1,
            sizeof(ASMacAudioQueueWriterAuthorizationGateStorage)
        );
    if (storage == NULL) {
        return NULL;
    }

    atomic_init(&storage->state, 0);
    return storage;
}

void ASMacAudioQueueWriterAuthorizationGateDestroy(
    ASMacAudioQueueWriterAuthorizationGateRef gate
) {
    if (gate == NULL) {
        return;
    }

    free((ASMacAudioQueueWriterAuthorizationGateStorage *)gate);
}

uint64_t ASMacAudioQueueWriterAuthorizationGatePrepareToOpen(
    ASMacAudioQueueWriterAuthorizationGateRef gate
) {
    if (gate == NULL) {
        return UINT64_MAX;
    }

    ASMacAudioQueueWriterAuthorizationGateStorage *storage =
        (ASMacAudioQueueWriterAuthorizationGateStorage *)gate;
    return (uint64_t)(atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    ) >> 1);
}

bool ASMacAudioQueueWriterAuthorizationGateOpenIfUnchanged(
    ASMacAudioQueueWriterAuthorizationGateRef gate,
    uint64_t expectedGeneration
) {
    if (gate == NULL || expectedGeneration > (UINT64_MAX >> 1)) {
        return false;
    }

    ASMacAudioQueueWriterAuthorizationGateStorage *storage =
        (ASMacAudioQueueWriterAuthorizationGateStorage *)gate;
    uint_fast64_t observed = atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    );
    for (;;) {
        if ((observed >> 1) != expectedGeneration) {
            return false;
        }
        const uint_fast64_t desired =
            observed | ASMacAudioQueueWriterAuthorizationOpenBit;
        if (atomic_compare_exchange_weak_explicit(
                &storage->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire
            )) {
            return true;
        }
    }
}

void ASMacAudioQueueWriterAuthorizationGateClose(
    ASMacAudioQueueWriterAuthorizationGateRef gate
) {
    if (gate == NULL) {
        return;
    }

    ASMacAudioQueueWriterAuthorizationGateStorage *storage =
        (ASMacAudioQueueWriterAuthorizationGateStorage *)gate;
    uint_fast64_t observed = atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    );
    for (;;) {
        const uint_fast64_t generation = observed >> 1;
        const uint_fast64_t nextGeneration = generation + 1;
        const uint_fast64_t desired = nextGeneration << 1;
        if (atomic_compare_exchange_weak_explicit(
                &storage->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire
            )) {
            return;
        }
    }
}

bool ASMacAudioQueueWriterAuthorizationGateIsOpen(
    ASMacAudioQueueWriterAuthorizationGateRef gate
) {
    if (gate == NULL) {
        return false;
    }

    ASMacAudioQueueWriterAuthorizationGateStorage *storage =
        (ASMacAudioQueueWriterAuthorizationGateStorage *)gate;
    return (atomic_load_explicit(
        &storage->state,
        memory_order_acquire
    ) & ASMacAudioQueueWriterAuthorizationOpenBit) != 0;
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

typedef struct ASMacAudioQueuePCMContentSlot {
    atomic_uint_fast64_t sequence;
    atomic_uint_fast64_t completedFrameCount;
    atomic_uint_fast64_t sourceStartFrame;
    atomic_uint_fast64_t sourceEndFrame;
    atomic_uint_fast64_t windowFingerprint;
    atomic_uint_fast64_t frameCount;
    atomic_uint_fast64_t leftSampleSumBits;
    atomic_uint_fast64_t rightSampleSumBits;
    atomic_uint_fast64_t leftSquareSum;
    atomic_uint_fast64_t rightSquareSum;
    atomic_uint_fast64_t leftRightProductSumBits;
    atomic_uint_fast64_t sumSquareSum;
    atomic_uint_fast64_t differenceSquareSum;
    atomic_uint_fast64_t leftPeak;
    atomic_uint_fast64_t rightPeak;
    atomic_uint_fast64_t leftZeroCount;
    atomic_uint_fast64_t rightZeroCount;
    atomic_uint_fast64_t leftClippingCount;
    atomic_uint_fast64_t rightClippingCount;
    atomic_uint_fast64_t oneSidedFrameCount;
} ASMacAudioQueuePCMContentSlot;

typedef struct ASMacAudioQueuePCMContentStorage {
    atomic_uint_fast64_t lifecycleGeneration;
    atomic_uint_fast64_t publishedSequence;
    uint64_t nextSequence;
    uint64_t completedFrameCount;
#if DEBUG
    atomic_bool holdReadForTesting;
    atomic_bool readIsHeldForTesting;
#endif
    ASMacAudioQueuePCMContentSlot slots[2];
} ASMacAudioQueuePCMContentStorage;

static uint64_t ASMacAudioQueuePCMContentSignedBits(
    int64_t value
) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static int64_t ASMacAudioQueuePCMContentSignedFromBits(
    uint64_t bits
) {
    int64_t value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void ASMacAudioQueuePCMContentInitializeSlot(
    ASMacAudioQueuePCMContentSlot *slot
) {
    atomic_init(&slot->sequence, 0);
    atomic_init(&slot->completedFrameCount, 0);
    atomic_init(&slot->sourceStartFrame, 0);
    atomic_init(&slot->sourceEndFrame, 0);
    atomic_init(&slot->windowFingerprint, 0);
    atomic_init(&slot->frameCount, 0);
    atomic_init(&slot->leftSampleSumBits, 0);
    atomic_init(&slot->rightSampleSumBits, 0);
    atomic_init(&slot->leftSquareSum, 0);
    atomic_init(&slot->rightSquareSum, 0);
    atomic_init(&slot->leftRightProductSumBits, 0);
    atomic_init(&slot->sumSquareSum, 0);
    atomic_init(&slot->differenceSquareSum, 0);
    atomic_init(&slot->leftPeak, 0);
    atomic_init(&slot->rightPeak, 0);
    atomic_init(&slot->leftZeroCount, 0);
    atomic_init(&slot->rightZeroCount, 0);
    atomic_init(&slot->leftClippingCount, 0);
    atomic_init(&slot->rightClippingCount, 0);
    atomic_init(&slot->oneSidedFrameCount, 0);
}

static void ASMacAudioQueuePCMContentResetSlot(
    ASMacAudioQueuePCMContentSlot *slot
) {
    atomic_store_explicit(
        &slot->sequence,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->completedFrameCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(&slot->sourceStartFrame, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->sourceEndFrame, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->windowFingerprint, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->frameCount, 0, memory_order_seq_cst);
    atomic_store_explicit(
        &slot->leftSampleSumBits,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightSampleSumBits,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftSquareSum,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightSquareSum,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftRightProductSumBits,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->sumSquareSum,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->differenceSquareSum,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(&slot->leftPeak, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->rightPeak, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->leftZeroCount, 0, memory_order_seq_cst);
    atomic_store_explicit(&slot->rightZeroCount, 0, memory_order_seq_cst);
    atomic_store_explicit(
        &slot->leftClippingCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightClippingCount,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->oneSidedFrameCount,
        0,
        memory_order_seq_cst
    );
}

static void ASMacAudioQueuePCMContentStoreSlot(
    ASMacAudioQueuePCMContentSlot *slot,
    uint64_t sequence,
    uint64_t completedFrameCount,
    ASMacAudioQueuePCMContentRawWindow window
) {
    // Invalidate the recycled slot before changing any payload member. A
    // reader validates both this sequence and the global publication sequence.
    atomic_store_explicit(
        &slot->sequence,
        0,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->completedFrameCount,
        completedFrameCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->sourceStartFrame,
        window.sourceStartFrame,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->sourceEndFrame,
        window.sourceEndFrame,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->windowFingerprint,
        window.windowFingerprint,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->frameCount,
        window.frameCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftSampleSumBits,
        ASMacAudioQueuePCMContentSignedBits(window.leftSampleSum),
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightSampleSumBits,
        ASMacAudioQueuePCMContentSignedBits(window.rightSampleSum),
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftSquareSum,
        window.leftSquareSum,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightSquareSum,
        window.rightSquareSum,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftRightProductSumBits,
        ASMacAudioQueuePCMContentSignedBits(
            window.leftRightProductSum
        ),
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->sumSquareSum,
        window.sumSquareSum,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->differenceSquareSum,
        window.differenceSquareSum,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftPeak,
        window.leftPeak,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightPeak,
        window.rightPeak,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftZeroCount,
        window.leftZeroCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightZeroCount,
        window.rightZeroCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->leftClippingCount,
        window.leftClippingCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->rightClippingCount,
        window.rightClippingCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->oneSidedFrameCount,
        window.oneSidedFrameCount,
        memory_order_seq_cst
    );
    atomic_store_explicit(
        &slot->sequence,
        sequence,
        memory_order_seq_cst
    );
}

static ASMacAudioQueuePCMContentRawWindow
ASMacAudioQueuePCMContentLoadSlot(
    ASMacAudioQueuePCMContentSlot *slot
) {
    ASMacAudioQueuePCMContentRawWindow window = {0};
    window.sourceStartFrame = atomic_load_explicit(
        &slot->sourceStartFrame,
        memory_order_seq_cst
    );
    window.sourceEndFrame = atomic_load_explicit(
        &slot->sourceEndFrame,
        memory_order_seq_cst
    );
    window.windowFingerprint = atomic_load_explicit(
        &slot->windowFingerprint,
        memory_order_seq_cst
    );
    window.frameCount = atomic_load_explicit(
        &slot->frameCount,
        memory_order_seq_cst
    );
    window.leftSampleSum = ASMacAudioQueuePCMContentSignedFromBits(
        atomic_load_explicit(
            &slot->leftSampleSumBits,
            memory_order_seq_cst
        )
    );
    window.rightSampleSum = ASMacAudioQueuePCMContentSignedFromBits(
        atomic_load_explicit(
            &slot->rightSampleSumBits,
            memory_order_seq_cst
        )
    );
    window.leftSquareSum = atomic_load_explicit(
        &slot->leftSquareSum,
        memory_order_seq_cst
    );
    window.rightSquareSum = atomic_load_explicit(
        &slot->rightSquareSum,
        memory_order_seq_cst
    );
    window.leftRightProductSum =
        ASMacAudioQueuePCMContentSignedFromBits(
            atomic_load_explicit(
                &slot->leftRightProductSumBits,
                memory_order_seq_cst
            )
        );
    window.sumSquareSum = atomic_load_explicit(
        &slot->sumSquareSum,
        memory_order_seq_cst
    );
    window.differenceSquareSum = atomic_load_explicit(
        &slot->differenceSquareSum,
        memory_order_seq_cst
    );
    window.leftPeak = atomic_load_explicit(
        &slot->leftPeak,
        memory_order_seq_cst
    );
    window.rightPeak = atomic_load_explicit(
        &slot->rightPeak,
        memory_order_seq_cst
    );
    window.leftZeroCount = atomic_load_explicit(
        &slot->leftZeroCount,
        memory_order_seq_cst
    );
    window.rightZeroCount = atomic_load_explicit(
        &slot->rightZeroCount,
        memory_order_seq_cst
    );
    window.leftClippingCount = atomic_load_explicit(
        &slot->leftClippingCount,
        memory_order_seq_cst
    );
    window.rightClippingCount = atomic_load_explicit(
        &slot->rightClippingCount,
        memory_order_seq_cst
    );
    window.oneSidedFrameCount = atomic_load_explicit(
        &slot->oneSidedFrameCount,
        memory_order_seq_cst
    );
    return window;
}

ASMacAudioQueuePCMContentRef
ASMacAudioQueuePCMContentCreate(void) {
    ASMacAudioQueuePCMContentStorage *storage =
        calloc(1, sizeof(ASMacAudioQueuePCMContentStorage));
    if (storage == NULL) {
        return NULL;
    }

    atomic_init(&storage->lifecycleGeneration, 1);
    atomic_init(&storage->publishedSequence, 0);
#if DEBUG
    atomic_init(&storage->holdReadForTesting, false);
    atomic_init(&storage->readIsHeldForTesting, false);
#endif
    ASMacAudioQueuePCMContentInitializeSlot(&storage->slots[0]);
    ASMacAudioQueuePCMContentInitializeSlot(&storage->slots[1]);
    return storage;
}

void ASMacAudioQueuePCMContentDestroy(
    ASMacAudioQueuePCMContentRef content
) {
    if (content == NULL) {
        return;
    }
    free((ASMacAudioQueuePCMContentStorage *)content);
}

void ASMacAudioQueuePCMContentReset(
    ASMacAudioQueuePCMContentRef content
) {
    if (content == NULL) {
        return;
    }

    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    atomic_store_explicit(
        &storage->publishedSequence,
        0,
        memory_order_seq_cst
    );
    uint64_t lifecycleGeneration = atomic_load_explicit(
        &storage->lifecycleGeneration,
        memory_order_seq_cst
    );
    if (lifecycleGeneration != UINT64_MAX) {
        lifecycleGeneration += 1;
        atomic_store_explicit(
            &storage->lifecycleGeneration,
            lifecycleGeneration,
            memory_order_seq_cst
        );
    }
    ASMacAudioQueuePCMContentResetSlot(&storage->slots[0]);
    ASMacAudioQueuePCMContentResetSlot(&storage->slots[1]);
    storage->completedFrameCount = 0;
}

void ASMacAudioQueuePCMContentPublish(
    ASMacAudioQueuePCMContentRef content,
    ASMacAudioQueuePCMContentRawWindow window
) {
    if (content == NULL || window.frameCount == 0) {
        return;
    }

    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    if (storage->nextSequence == UINT64_MAX) {
        // Never reuse a publication identity: exhaustion fails closed instead of
        // reintroducing an ABA after an astronomically long process lifetime.
        return;
    }
    const uint64_t sequence = storage->nextSequence + 1;
    const uint64_t completedFrameCount =
        storage->completedFrameCount + window.frameCount;
    ASMacAudioQueuePCMContentSlot *slot =
        &storage->slots[sequence & 1];
    ASMacAudioQueuePCMContentStoreSlot(
        slot,
        sequence,
        completedFrameCount,
        window
    );
    storage->nextSequence = sequence;
    storage->completedFrameCount = completedFrameCount;
    atomic_store_explicit(
        &storage->publishedSequence,
        sequence,
        memory_order_seq_cst
    );
}

ASMacAudioQueuePCMContentSnapshot
ASMacAudioQueuePCMContentRead(
    ASMacAudioQueuePCMContentRef content
) {
    ASMacAudioQueuePCMContentSnapshot snapshot = {0};
    if (content == NULL) {
        return snapshot;
    }

    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    for (int attempt = 0; attempt < 4; attempt += 1) {
        const uint64_t lifecycleGeneration = atomic_load_explicit(
            &storage->lifecycleGeneration,
            memory_order_seq_cst
        );
        const uint64_t sequence = atomic_load_explicit(
            &storage->publishedSequence,
            memory_order_seq_cst
        );
        if (sequence == 0) {
            if (atomic_load_explicit(
                    &storage->lifecycleGeneration,
                    memory_order_seq_cst
                ) == lifecycleGeneration) {
                snapshot.lifecycleGeneration = lifecycleGeneration;
                return snapshot;
            }
            continue;
        }

#if DEBUG
        if (atomic_exchange_explicit(
                &storage->holdReadForTesting,
                false,
                memory_order_acq_rel
            )) {
            atomic_store_explicit(
                &storage->readIsHeldForTesting,
                true,
                memory_order_release
            );
            while (atomic_load_explicit(
                &storage->readIsHeldForTesting,
                memory_order_acquire
            )) {
                sched_yield();
            }
        }
#endif

        ASMacAudioQueuePCMContentSlot *slot =
            &storage->slots[sequence & 1];
        if (atomic_load_explicit(
                &slot->sequence,
                memory_order_seq_cst
            ) != sequence) {
            continue;
        }
        const uint64_t completedFrameCount = atomic_load_explicit(
            &slot->completedFrameCount,
            memory_order_seq_cst
        );
        const ASMacAudioQueuePCMContentRawWindow window =
            ASMacAudioQueuePCMContentLoadSlot(slot);
        if (atomic_load_explicit(
                &slot->sequence,
                memory_order_seq_cst
            ) != sequence
            || atomic_load_explicit(
                &storage->publishedSequence,
                memory_order_seq_cst
            ) != sequence
            || atomic_load_explicit(
                &storage->lifecycleGeneration,
                memory_order_seq_cst
            ) != lifecycleGeneration) {
            continue;
        }

        snapshot.hasCompletedWindow = true;
        snapshot.lifecycleGeneration = lifecycleGeneration;
        snapshot.windowSequence = sequence;
        snapshot.completedFrameCount = completedFrameCount;
        snapshot.window = window;
        return snapshot;
    }
    snapshot.lifecycleGeneration = atomic_load_explicit(
        &storage->lifecycleGeneration,
        memory_order_seq_cst
    );
    return snapshot;
}

#if DEBUG
void ASMacAudioQueuePCMContentHoldReadForTesting(
    ASMacAudioQueuePCMContentRef content
) {
    if (content == NULL) {
        return;
    }
    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    atomic_store_explicit(
        &storage->holdReadForTesting,
        true,
        memory_order_release
    );
}

void ASMacAudioQueuePCMContentReleaseReadForTesting(
    ASMacAudioQueuePCMContentRef content
) {
    if (content == NULL) {
        return;
    }
    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    atomic_store_explicit(
        &storage->readIsHeldForTesting,
        false,
        memory_order_release
    );
}

bool ASMacAudioQueuePCMContentReadIsHeldForTesting(
    ASMacAudioQueuePCMContentRef content
) {
    if (content == NULL) {
        return false;
    }
    ASMacAudioQueuePCMContentStorage *storage =
        (ASMacAudioQueuePCMContentStorage *)content;
    return atomic_load_explicit(
        &storage->readIsHeldForTesting,
        memory_order_acquire
    );
}
#endif

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

enum { ASMacDecodedTelemetryWindowTargetFrames = 48000 };

/// Fixed-size scalar evidence for one native render. This value lives only on the callback stack;
/// it never owns or points at PCM.
typedef struct ASMacDecodedPlayoutBlockScalars {
    uint64_t sourceStartFrame;
    uint64_t sourceEndFrame;
    uint64_t frameCount;
    uint64_t byteCount;
    int64_t leftSum;
    int64_t rightSum;
    double leftSquareSum;
    double rightSquareSum;
    double crossSum;
    double sumSquareSum;
    double differenceSquareSum;
    uint32_t leftPeakMagnitude;
    uint32_t rightPeakMagnitude;
    uint64_t leftZeroSampleCount;
    uint64_t rightZeroSampleCount;
    uint64_t leftClippedSampleCount;
    uint64_t rightClippedSampleCount;
    uint64_t leftActiveFrameCount;
    uint64_t rightActiveFrameCount;
    uint64_t oneSidedFrameCount;
    uint64_t fingerprint;
    uint64_t windowFingerprint;
} ASMacDecodedPlayoutBlockScalars;

/// Callback-owned current window. Access is serialized by a nonblocking atomic writer claim.
typedef struct ASMacDecodedPlayoutWindowScalars {
    uint64_t generation;
    uint64_t firstRenderCall;
    uint64_t lastRenderCall;
    uint64_t renderCallCount;
    uint64_t sourceStartFrame;
    uint64_t sourceEndFrame;
    uint64_t fingerprint;
    uint64_t frameCount;
    uint64_t byteCount;
    int64_t leftSum;
    int64_t rightSum;
    double leftSquareSum;
    double rightSquareSum;
    double crossSum;
    double sumSquareSum;
    double differenceSquareSum;
    uint32_t leftPeakMagnitude;
    uint32_t rightPeakMagnitude;
    uint64_t leftZeroSampleCount;
    uint64_t rightZeroSampleCount;
    uint64_t leftClippedSampleCount;
    uint64_t rightClippedSampleCount;
    uint64_t leftActiveFrameCount;
    uint64_t rightActiveFrameCount;
    uint64_t oneSidedFrameCount;
    uint64_t allZeroBlockCount;
    uint64_t leftOnlyBlockCount;
    uint64_t rightOnlyBlockCount;
    uint64_t frozenBlockCount;
    uint64_t currentFrozenBlockRun;
    uint64_t longestFrozenBlockRun;
} ASMacDecodedPlayoutWindowScalars;

/// One atomically readable publication slot. Every payload member is atomic so the sequence
/// validation is data-race-free under the C memory model.
typedef struct ASMacDecodedPlayoutWindowSlot {
    atomic_uint_fast64_t sequence;
    atomic_uint_fast64_t generation;
    atomic_uint_fast64_t firstRenderCall;
    atomic_uint_fast64_t lastRenderCall;
    atomic_uint_fast64_t renderCallCount;
    atomic_uint_fast64_t sourceStartFrame;
    atomic_uint_fast64_t sourceEndFrame;
    atomic_uint_fast64_t fingerprint;
    atomic_uint_fast64_t frameCount;
    atomic_uint_fast64_t byteCount;
    atomic_uint_fast64_t leftSumBits;
    atomic_uint_fast64_t rightSumBits;
    atomic_uint_fast64_t leftSquareSumBits;
    atomic_uint_fast64_t rightSquareSumBits;
    atomic_uint_fast64_t crossSumBits;
    atomic_uint_fast64_t sumSquareSumBits;
    atomic_uint_fast64_t differenceSquareSumBits;
    atomic_uint_fast64_t leftPeakMagnitude;
    atomic_uint_fast64_t rightPeakMagnitude;
    atomic_uint_fast64_t leftZeroSampleCount;
    atomic_uint_fast64_t rightZeroSampleCount;
    atomic_uint_fast64_t leftClippedSampleCount;
    atomic_uint_fast64_t rightClippedSampleCount;
    atomic_uint_fast64_t leftActiveFrameCount;
    atomic_uint_fast64_t rightActiveFrameCount;
    atomic_uint_fast64_t oneSidedFrameCount;
    atomic_uint_fast64_t allZeroBlockCount;
    atomic_uint_fast64_t leftOnlyBlockCount;
    atomic_uint_fast64_t rightOnlyBlockCount;
    atomic_uint_fast64_t frozenBlockCount;
    atomic_uint_fast64_t longestFrozenBlockRun;
} ASMacDecodedPlayoutWindowSlot;

typedef struct ASMacDecodedPlayoutPublishedWindow {
    uint64_t sequence;
    ASMacDecodedPlayoutWindowScalars scalars;
} ASMacDecodedPlayoutPublishedWindow;

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

    // Decoded-content telemetry is independent of the lifecycle/state locks. The render callback
    // does one bounded scalar pass, then either claims this writer flag immediately or drops only
    // telemetry. Two all-atomic publication slots make off-callback reads consistent.
    atomic_flag decodedTelemetryWriter;
    atomic_uint_fast64_t decodedTelemetryGeneration;
    atomic_uint_fast64_t decodedRenderCallCount;
    atomic_uint_fast64_t decodedRequestedFrameCount;
    atomic_uint_fast64_t decodedRequestedByteCount;
    atomic_uint_fast64_t decodedReturnedByteCount;
    atomic_uint_fast64_t decodedNativeSuccessRenderCallCount;
    atomic_uint_fast64_t decodedNativeFailureRenderCallCount;
    atomic_uint_fast64_t decodedExactBufferContractCount;
    atomic_uint_fast64_t decodedBufferContractMismatchCount;
    atomic_uint_fast64_t decodedAnalyzedRenderCallCount;
    atomic_uint_fast64_t decodedAnalyzedFrameCount;
    atomic_uint_fast64_t decodedAnalyzedByteCount;
    atomic_uint_fast64_t decodedDroppedTelemetryRenderCallCount;
    atomic_uint_fast64_t decodedPendingWindowFrameCount;
    atomic_uint_fast64_t decodedLatestRenderSequence;
    atomic_int decodedLatestRenderStatus;
    atomic_uint decodedLatestRequestedFrameCount;
    atomic_uint decodedLatestRequestedByteCount;
    atomic_uint decodedLatestReturnedByteCount;
    atomic_bool decodedLatestBufferContractWasExact;
    uint64_t decodedPublishedRenderCall;
    uint64_t decodedNextWindowSequence;
    ASMacDecodedPlayoutWindowScalars decodedCurrentWindow;
    BOOL decodedPreviousBlockIsValid;
    uint64_t decodedPreviousBlockFingerprint;
    uint64_t decodedPreviousBlockFrameCount;
    ASMacDecodedPlayoutWindowSlot decodedCompletedWindows[2];
#if DEBUG
    atomic_bool holdDecodedTelemetryReadForTesting;
    atomic_bool decodedTelemetryReadIsHeldForTesting;
#endif
} ASMacStereoAudioDeviceState;

static uint64_t ASMacDecodedDoubleBits(double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double ASMacDecodedDoubleFromBits(uint64_t bits) {
    double value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static uint64_t ASMacDecodedSignedBits(int64_t value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static int64_t ASMacDecodedSignedFromBits(uint64_t bits) {
    int64_t value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void ASMacDecodedInitializeWindowSlot(
    ASMacDecodedPlayoutWindowSlot *slot
) {
    atomic_init(&slot->sequence, 0);
    atomic_init(&slot->generation, 0);
    atomic_init(&slot->firstRenderCall, 0);
    atomic_init(&slot->lastRenderCall, 0);
    atomic_init(&slot->renderCallCount, 0);
    atomic_init(&slot->sourceStartFrame, 0);
    atomic_init(&slot->sourceEndFrame, 0);
    atomic_init(&slot->fingerprint, 0);
    atomic_init(&slot->frameCount, 0);
    atomic_init(&slot->byteCount, 0);
    atomic_init(&slot->leftSumBits, 0);
    atomic_init(&slot->rightSumBits, 0);
    atomic_init(&slot->leftSquareSumBits, 0);
    atomic_init(&slot->rightSquareSumBits, 0);
    atomic_init(&slot->crossSumBits, 0);
    atomic_init(&slot->sumSquareSumBits, 0);
    atomic_init(&slot->differenceSquareSumBits, 0);
    atomic_init(&slot->leftPeakMagnitude, 0);
    atomic_init(&slot->rightPeakMagnitude, 0);
    atomic_init(&slot->leftZeroSampleCount, 0);
    atomic_init(&slot->rightZeroSampleCount, 0);
    atomic_init(&slot->leftClippedSampleCount, 0);
    atomic_init(&slot->rightClippedSampleCount, 0);
    atomic_init(&slot->leftActiveFrameCount, 0);
    atomic_init(&slot->rightActiveFrameCount, 0);
    atomic_init(&slot->oneSidedFrameCount, 0);
    atomic_init(&slot->allZeroBlockCount, 0);
    atomic_init(&slot->leftOnlyBlockCount, 0);
    atomic_init(&slot->rightOnlyBlockCount, 0);
    atomic_init(&slot->frozenBlockCount, 0);
    atomic_init(&slot->longestFrozenBlockRun, 0);
}

static void ASMacDecodedInitializeTelemetry(
    ASMacStereoAudioDeviceState *state
) {
    atomic_flag_clear(&state->decodedTelemetryWriter);
    atomic_init(&state->decodedTelemetryGeneration, 0);
    atomic_init(&state->decodedRenderCallCount, 0);
    atomic_init(&state->decodedRequestedFrameCount, 0);
    atomic_init(&state->decodedRequestedByteCount, 0);
    atomic_init(&state->decodedReturnedByteCount, 0);
    atomic_init(&state->decodedNativeSuccessRenderCallCount, 0);
    atomic_init(&state->decodedNativeFailureRenderCallCount, 0);
    atomic_init(&state->decodedExactBufferContractCount, 0);
    atomic_init(&state->decodedBufferContractMismatchCount, 0);
    atomic_init(&state->decodedAnalyzedRenderCallCount, 0);
    atomic_init(&state->decodedAnalyzedFrameCount, 0);
    atomic_init(&state->decodedAnalyzedByteCount, 0);
    atomic_init(&state->decodedDroppedTelemetryRenderCallCount, 0);
    atomic_init(&state->decodedPendingWindowFrameCount, 0);
    atomic_init(&state->decodedLatestRenderSequence, 0);
    atomic_init(&state->decodedLatestRenderStatus, noErr);
    atomic_init(&state->decodedLatestRequestedFrameCount, 0);
    atomic_init(&state->decodedLatestRequestedByteCount, 0);
    atomic_init(&state->decodedLatestReturnedByteCount, 0);
    atomic_init(&state->decodedLatestBufferContractWasExact, false);
#if DEBUG
    atomic_init(&state->holdDecodedTelemetryReadForTesting, false);
    atomic_init(&state->decodedTelemetryReadIsHeldForTesting, false);
#endif
    ASMacDecodedInitializeWindowSlot(&state->decodedCompletedWindows[0]);
    ASMacDecodedInitializeWindowSlot(&state->decodedCompletedWindows[1]);
}

static ASMacDecodedPlayoutBlockScalars ASMacDecodedAnalyzeBlock(
    const int16_t *samples,
    uint64_t sourceStartFrame,
    uint64_t frameCount,
    uint64_t initialWindowFingerprint
) {
    static const uint64_t fnvOffsetBasis = UINT64_C(14695981039346656037);
    static const uint64_t fnvPrime = UINT64_C(1099511628211);
    ASMacDecodedPlayoutBlockScalars block = {
        .sourceStartFrame = sourceStartFrame,
        .sourceEndFrame = sourceStartFrame + frameCount,
        .frameCount = frameCount,
        .byteCount = frameCount * ASAudioChannelCount * sizeof(int16_t),
        .fingerprint = fnvOffsetBasis,
        .windowFingerprint = initialWindowFingerprint,
    };
    for (uint64_t frame = 0; frame < frameCount; frame += 1) {
        const int32_t left = samples[frame * ASAudioChannelCount];
        const int32_t right = samples[frame * ASAudioChannelCount + 1];
        const uint32_t leftMagnitude = (uint32_t)(left < 0 ? -left : left);
        const uint32_t rightMagnitude = (uint32_t)(right < 0 ? -right : right);
        const int32_t sum = left + right;
        const int32_t difference = left - right;

        block.leftSum += left;
        block.rightSum += right;
        block.leftSquareSum += (double)left * left;
        block.rightSquareSum += (double)right * right;
        block.crossSum += (double)left * right;
        block.sumSquareSum += (double)sum * sum;
        block.differenceSquareSum += (double)difference * difference;
        if (leftMagnitude > block.leftPeakMagnitude) {
            block.leftPeakMagnitude = leftMagnitude;
        }
        if (rightMagnitude > block.rightPeakMagnitude) {
            block.rightPeakMagnitude = rightMagnitude;
        }
        block.leftZeroSampleCount += left == 0;
        block.rightZeroSampleCount += right == 0;
        block.leftClippedSampleCount += leftMagnitude >= 32760;
        block.rightClippedSampleCount += rightMagnitude >= 32760;
        const BOOL leftIsActive = leftMagnitude >= 128;
        const BOOL rightIsActive = rightMagnitude >= 128;
        block.leftActiveFrameCount += leftIsActive;
        block.rightActiveFrameCount += rightIsActive;
        block.oneSidedFrameCount += leftIsActive != rightIsActive;

        // Canonical, cross-boundary-compatible FNV-1a: each signed sample is
        // reinterpreted as UInt16 and hashed low byte then high byte, L then R.
        const uint16_t sampleValues[ASAudioChannelCount] = {
            (uint16_t)left,
            (uint16_t)right,
        };
        for (NSUInteger channel = 0; channel < ASAudioChannelCount; channel += 1) {
            const uint16_t value = sampleValues[channel];
            const uint8_t lowByte = (uint8_t)(value & UINT16_C(0x00ff));
            const uint8_t highByte = (uint8_t)(value >> 8);
            block.fingerprint ^= lowByte;
            block.fingerprint *= fnvPrime;
            block.fingerprint ^= highByte;
            block.fingerprint *= fnvPrime;
            block.windowFingerprint ^= lowByte;
            block.windowFingerprint *= fnvPrime;
            block.windowFingerprint ^= highByte;
            block.windowFingerprint *= fnvPrime;
        }
    }
    return block;
}

static void ASMacDecodedPublishCompletedWindow(
    ASMacStereoAudioDeviceState *state
) {
    ASMacDecodedPlayoutWindowScalars *window = &state->decodedCurrentWindow;
    if (state->decodedNextWindowSequence == UINT64_MAX) {
        // Publication identities are never reused. Exhaustion fails closed.
        memset(window, 0, sizeof(*window));
        atomic_store_explicit(
            &state->decodedPendingWindowFrameCount,
            0,
            memory_order_relaxed
        );
        return;
    }
    const uint64_t windowSequence = state->decodedNextWindowSequence + 1;
    state->decodedNextWindowSequence = windowSequence;
    ASMacDecodedPlayoutWindowSlot *slot =
        &state->decodedCompletedWindows[windowSequence & 1];

    // Zero invalidates a recycled slot. Since completed identities never repeat,
    // a reader spanning reset/republication cannot observe an ABA.
    atomic_store_explicit(&slot->sequence, 0, memory_order_release);
    atomic_store_explicit(&slot->generation, window->generation, memory_order_relaxed);
    atomic_store_explicit(
        &slot->firstRenderCall,
        window->firstRenderCall,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->lastRenderCall,
        window->lastRenderCall,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->renderCallCount,
        window->renderCallCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->sourceStartFrame,
        window->sourceStartFrame,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->sourceEndFrame,
        window->sourceEndFrame,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->fingerprint,
        window->fingerprint,
        memory_order_relaxed
    );
    atomic_store_explicit(&slot->frameCount, window->frameCount, memory_order_relaxed);
    atomic_store_explicit(&slot->byteCount, window->byteCount, memory_order_relaxed);
    atomic_store_explicit(
        &slot->leftSumBits,
        ASMacDecodedSignedBits(window->leftSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightSumBits,
        ASMacDecodedSignedBits(window->rightSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftSquareSumBits,
        ASMacDecodedDoubleBits(window->leftSquareSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightSquareSumBits,
        ASMacDecodedDoubleBits(window->rightSquareSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->crossSumBits,
        ASMacDecodedDoubleBits(window->crossSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->sumSquareSumBits,
        ASMacDecodedDoubleBits(window->sumSquareSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->differenceSquareSumBits,
        ASMacDecodedDoubleBits(window->differenceSquareSum),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftPeakMagnitude,
        window->leftPeakMagnitude,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightPeakMagnitude,
        window->rightPeakMagnitude,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftZeroSampleCount,
        window->leftZeroSampleCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightZeroSampleCount,
        window->rightZeroSampleCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftClippedSampleCount,
        window->leftClippedSampleCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightClippedSampleCount,
        window->rightClippedSampleCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftActiveFrameCount,
        window->leftActiveFrameCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightActiveFrameCount,
        window->rightActiveFrameCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->oneSidedFrameCount,
        window->oneSidedFrameCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->allZeroBlockCount,
        window->allZeroBlockCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->leftOnlyBlockCount,
        window->leftOnlyBlockCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->rightOnlyBlockCount,
        window->rightOnlyBlockCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->frozenBlockCount,
        window->frozenBlockCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &slot->longestFrozenBlockRun,
        window->longestFrozenBlockRun,
        memory_order_relaxed
    );
    atomic_store_explicit(&slot->sequence, windowSequence, memory_order_release);

    memset(window, 0, sizeof(*window));
    atomic_store_explicit(
        &state->decodedPendingWindowFrameCount,
        0,
        memory_order_relaxed
    );
}

static void ASMacDecodedAccumulateBlock(
    ASMacStereoAudioDeviceState *state,
    const ASMacDecodedPlayoutBlockScalars *block,
    uint64_t renderCall
) {
    ASMacDecodedPlayoutWindowScalars *window = &state->decodedCurrentWindow;
    if (window->frameCount == 0) {
        window->generation = atomic_load_explicit(
            &state->decodedTelemetryGeneration,
            memory_order_relaxed
        );
        window->firstRenderCall = renderCall;
        window->sourceStartFrame = block->sourceStartFrame;
        window->fingerprint = UINT64_C(14695981039346656037);
    }
    window->lastRenderCall = renderCall;
    window->renderCallCount += 1;
    window->sourceEndFrame = block->sourceEndFrame;
    window->fingerprint = block->windowFingerprint;
    window->frameCount += block->frameCount;
    window->byteCount += block->byteCount;
    window->leftSum += block->leftSum;
    window->rightSum += block->rightSum;
    window->leftSquareSum += block->leftSquareSum;
    window->rightSquareSum += block->rightSquareSum;
    window->crossSum += block->crossSum;
    window->sumSquareSum += block->sumSquareSum;
    window->differenceSquareSum += block->differenceSquareSum;
    if (block->leftPeakMagnitude > window->leftPeakMagnitude) {
        window->leftPeakMagnitude = block->leftPeakMagnitude;
    }
    if (block->rightPeakMagnitude > window->rightPeakMagnitude) {
        window->rightPeakMagnitude = block->rightPeakMagnitude;
    }
    window->leftZeroSampleCount += block->leftZeroSampleCount;
    window->rightZeroSampleCount += block->rightZeroSampleCount;
    window->leftClippedSampleCount += block->leftClippedSampleCount;
    window->rightClippedSampleCount += block->rightClippedSampleCount;
    window->leftActiveFrameCount += block->leftActiveFrameCount;
    window->rightActiveFrameCount += block->rightActiveFrameCount;
    window->oneSidedFrameCount += block->oneSidedFrameCount;

    const BOOL blockIsAllZero = block->leftSquareSum == 0
        && block->rightSquareSum == 0;
    const BOOL blockIsLeftOnly = block->leftActiveFrameCount > 0
        && block->rightActiveFrameCount == 0;
    const BOOL blockIsRightOnly = block->leftActiveFrameCount == 0
        && block->rightActiveFrameCount > 0;
    const BOOL blockIsFrozen = !blockIsAllZero
        && state->decodedPreviousBlockIsValid
        && state->decodedPreviousBlockFrameCount == block->frameCount
        && state->decodedPreviousBlockFingerprint == block->fingerprint;
    window->allZeroBlockCount += blockIsAllZero;
    window->leftOnlyBlockCount += blockIsLeftOnly;
    window->rightOnlyBlockCount += blockIsRightOnly;
    if (blockIsFrozen) {
        window->frozenBlockCount += 1;
        window->currentFrozenBlockRun += 1;
        if (window->currentFrozenBlockRun > window->longestFrozenBlockRun) {
            window->longestFrozenBlockRun = window->currentFrozenBlockRun;
        }
    } else {
        window->currentFrozenBlockRun = 0;
    }
    state->decodedPreviousBlockIsValid = YES;
    state->decodedPreviousBlockFingerprint = block->fingerprint;
    state->decodedPreviousBlockFrameCount = block->frameCount;

    atomic_store_explicit(
        &state->decodedPendingWindowFrameCount,
        window->frameCount,
        memory_order_relaxed
    );
    if (window->frameCount == ASMacDecodedTelemetryWindowTargetFrames) {
        ASMacDecodedPublishCompletedWindow(state);
    }
}

static void ASMacDecodedDiscardPendingWindow(
    ASMacStereoAudioDeviceState *state
) {
    memset(
        &state->decodedCurrentWindow,
        0,
        sizeof(state->decodedCurrentWindow)
    );
    state->decodedPreviousBlockIsValid = NO;
    state->decodedPreviousBlockFingerprint = 0;
    state->decodedPreviousBlockFrameCount = 0;
    atomic_store_explicit(
        &state->decodedPendingWindowFrameCount,
        0,
        memory_order_relaxed
    );
}

static void ASMacDecodedAccumulateSamples(
    ASMacStereoAudioDeviceState *state,
    const int16_t *samples,
    uint64_t sourceStartFrame,
    uint64_t frameCount,
    uint64_t renderCall
) {
    ASMacDecodedPlayoutWindowScalars *window = &state->decodedCurrentWindow;
    if (window->frameCount > 0
        && window->sourceEndFrame != sourceStartFrame) {
        // A failed/dropped render creates a source-frame gap. Never label a
        // non-contiguous scalar set as one exact half-open interval.
        ASMacDecodedDiscardPendingWindow(state);
    }

    uint64_t sourceOffset = 0;
    while (sourceOffset < frameCount) {
        window = &state->decodedCurrentWindow;
        if (window->frameCount == 0) {
            window->fingerprint = UINT64_C(14695981039346656037);
        }
        const uint64_t remainingWindowFrames =
            ASMacDecodedTelemetryWindowTargetFrames - window->frameCount;
        const uint64_t chunkFrameCount = MIN(
            remainingWindowFrames,
            frameCount - sourceOffset
        );
        const uint64_t chunkSourceStartFrame =
            sourceStartFrame + sourceOffset;
        const ASMacDecodedPlayoutBlockScalars block =
            ASMacDecodedAnalyzeBlock(
                samples + sourceOffset * ASAudioChannelCount,
                chunkSourceStartFrame,
                chunkFrameCount,
                window->fingerprint
            );
        ASMacDecodedAccumulateBlock(state, &block, renderCall);
        sourceOffset += chunkFrameCount;
    }
}

static void ASMacDecodedPublishRenderTelemetry(
    ASMacStereoAudioDeviceState *state,
    uint64_t renderCall,
    int32_t status,
    uint32_t requestedFrameCount,
    uint32_t requestedByteCount,
    uint32_t returnedByteCount,
    BOOL bufferContractWasExact,
    const int16_t *samples,
    uint64_t sourceStartFrame
) {
    if (atomic_flag_test_and_set_explicit(
            &state->decodedTelemetryWriter,
            memory_order_acquire
        )) {
        atomic_fetch_add_explicit(
            &state->decodedDroppedTelemetryRenderCallCount,
            1,
            memory_order_relaxed
        );
        return;
    }

    // Concurrent pulls are legal at the lifetime gate. If analysis completion arrives out of
    // render-call order, discard only that telemetry event rather than regressing the window.
    if (renderCall <= state->decodedPublishedRenderCall) {
        atomic_fetch_add_explicit(
            &state->decodedDroppedTelemetryRenderCallCount,
            1,
            memory_order_relaxed
        );
        atomic_flag_clear_explicit(
            &state->decodedTelemetryWriter,
            memory_order_release
        );
        return;
    }

    // Render calls are process-lifetime monotonic and never reset. Zero invalidates
    // the payload while it is replaced; the completed identity itself cannot ABA.
    atomic_store_explicit(
        &state->decodedLatestRenderSequence,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &state->decodedLatestRenderStatus,
        status,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestRequestedFrameCount,
        requestedFrameCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestRequestedByteCount,
        requestedByteCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestReturnedByteCount,
        returnedByteCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestBufferContractWasExact,
        bufferContractWasExact,
        memory_order_relaxed
    );
    state->decodedPublishedRenderCall = renderCall;
    atomic_store_explicit(
        &state->decodedLatestRenderSequence,
        renderCall,
        memory_order_release
    );

    if (samples != NULL) {
        ASMacDecodedAccumulateSamples(
            state,
            samples,
            sourceStartFrame,
            requestedFrameCount,
            renderCall
        );
        atomic_fetch_add_explicit(
            &state->decodedAnalyzedRenderCallCount,
            1,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &state->decodedAnalyzedFrameCount,
            requestedFrameCount,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &state->decodedAnalyzedByteCount,
            requestedByteCount,
            memory_order_relaxed
        );
    } else if (state->decodedCurrentWindow.frameCount > 0) {
        ASMacDecodedDiscardPendingWindow(state);
    }
    atomic_flag_clear_explicit(
        &state->decodedTelemetryWriter,
        memory_order_release
    );
}

static BOOL ASMacDecodedReadWindowSlot(
    ASMacStereoAudioDeviceState *state,
    const ASMacDecodedPlayoutWindowSlot *slot,
    ASMacDecodedPlayoutPublishedWindow *published
) {
    for (NSUInteger attempt = 0; attempt < 4; attempt += 1) {
        const uint64_t before = atomic_load_explicit(
            &slot->sequence,
            memory_order_acquire
        );
        if (before == 0) {
            continue;
        }
#if DEBUG
        if (atomic_exchange_explicit(
                &state->holdDecodedTelemetryReadForTesting,
                false,
                memory_order_acq_rel
            )) {
            atomic_store_explicit(
                &state->decodedTelemetryReadIsHeldForTesting,
                true,
                memory_order_release
            );
            while (atomic_load_explicit(
                &state->decodedTelemetryReadIsHeldForTesting,
                memory_order_acquire
            )) {
                sched_yield();
            }
        }
#endif
        ASMacDecodedPlayoutWindowScalars value = {0};
        value.generation = atomic_load_explicit(&slot->generation, memory_order_relaxed);
        value.firstRenderCall = atomic_load_explicit(
            &slot->firstRenderCall,
            memory_order_relaxed
        );
        value.lastRenderCall = atomic_load_explicit(
            &slot->lastRenderCall,
            memory_order_relaxed
        );
        value.renderCallCount = atomic_load_explicit(
            &slot->renderCallCount,
            memory_order_relaxed
        );
        value.sourceStartFrame = atomic_load_explicit(
            &slot->sourceStartFrame,
            memory_order_relaxed
        );
        value.sourceEndFrame = atomic_load_explicit(
            &slot->sourceEndFrame,
            memory_order_relaxed
        );
        value.fingerprint = atomic_load_explicit(
            &slot->fingerprint,
            memory_order_relaxed
        );
        value.frameCount = atomic_load_explicit(&slot->frameCount, memory_order_relaxed);
        value.byteCount = atomic_load_explicit(&slot->byteCount, memory_order_relaxed);
        value.leftSum = ASMacDecodedSignedFromBits(atomic_load_explicit(
            &slot->leftSumBits,
            memory_order_relaxed
        ));
        value.rightSum = ASMacDecodedSignedFromBits(atomic_load_explicit(
            &slot->rightSumBits,
            memory_order_relaxed
        ));
        value.leftSquareSum = ASMacDecodedDoubleFromBits(atomic_load_explicit(
            &slot->leftSquareSumBits,
            memory_order_relaxed
        ));
        value.rightSquareSum = ASMacDecodedDoubleFromBits(atomic_load_explicit(
            &slot->rightSquareSumBits,
            memory_order_relaxed
        ));
        value.crossSum = ASMacDecodedDoubleFromBits(atomic_load_explicit(
            &slot->crossSumBits,
            memory_order_relaxed
        ));
        value.sumSquareSum = ASMacDecodedDoubleFromBits(atomic_load_explicit(
            &slot->sumSquareSumBits,
            memory_order_relaxed
        ));
        value.differenceSquareSum = ASMacDecodedDoubleFromBits(atomic_load_explicit(
            &slot->differenceSquareSumBits,
            memory_order_relaxed
        ));
        value.leftPeakMagnitude = (uint32_t)atomic_load_explicit(
            &slot->leftPeakMagnitude,
            memory_order_relaxed
        );
        value.rightPeakMagnitude = (uint32_t)atomic_load_explicit(
            &slot->rightPeakMagnitude,
            memory_order_relaxed
        );
        value.leftZeroSampleCount = atomic_load_explicit(
            &slot->leftZeroSampleCount,
            memory_order_relaxed
        );
        value.rightZeroSampleCount = atomic_load_explicit(
            &slot->rightZeroSampleCount,
            memory_order_relaxed
        );
        value.leftClippedSampleCount = atomic_load_explicit(
            &slot->leftClippedSampleCount,
            memory_order_relaxed
        );
        value.rightClippedSampleCount = atomic_load_explicit(
            &slot->rightClippedSampleCount,
            memory_order_relaxed
        );
        value.leftActiveFrameCount = atomic_load_explicit(
            &slot->leftActiveFrameCount,
            memory_order_relaxed
        );
        value.rightActiveFrameCount = atomic_load_explicit(
            &slot->rightActiveFrameCount,
            memory_order_relaxed
        );
        value.oneSidedFrameCount = atomic_load_explicit(
            &slot->oneSidedFrameCount,
            memory_order_relaxed
        );
        value.allZeroBlockCount = atomic_load_explicit(
            &slot->allZeroBlockCount,
            memory_order_relaxed
        );
        value.leftOnlyBlockCount = atomic_load_explicit(
            &slot->leftOnlyBlockCount,
            memory_order_relaxed
        );
        value.rightOnlyBlockCount = atomic_load_explicit(
            &slot->rightOnlyBlockCount,
            memory_order_relaxed
        );
        value.frozenBlockCount = atomic_load_explicit(
            &slot->frozenBlockCount,
            memory_order_relaxed
        );
        value.longestFrozenBlockRun = atomic_load_explicit(
            &slot->longestFrozenBlockRun,
            memory_order_relaxed
        );
        const uint64_t after = atomic_load_explicit(
            &slot->sequence,
            memory_order_acquire
        );
        if (before == after) {
            published->sequence = after;
            published->scalars = value;
            return YES;
        }
    }
    return NO;
}

static BOOL ASMacDecodedReadLatestCompletedWindow(
    ASMacStereoAudioDeviceState *state,
    ASMacDecodedPlayoutPublishedWindow *latest
) {
    ASMacDecodedPlayoutPublishedWindow first = {0};
    ASMacDecodedPlayoutPublishedWindow second = {0};
    const BOOL hasFirst = ASMacDecodedReadWindowSlot(
        state,
        &state->decodedCompletedWindows[0],
        &first
    );
    const BOOL hasSecond = ASMacDecodedReadWindowSlot(
        state,
        &state->decodedCompletedWindows[1],
        &second
    );
    if (!hasFirst && !hasSecond) {
        return NO;
    }
    *latest = !hasSecond || (hasFirst && first.sequence > second.sequence)
        ? first
        : second;
    return YES;
}

/// Valid only after StopPlayout has fenced all callbacks, or before the first StartPlayout.
static void ASMacDecodedResetTelemetryGeneration(
    ASMacStereoAudioDeviceState *state
) {
    uint64_t generation = atomic_load_explicit(
        &state->decodedTelemetryGeneration,
        memory_order_relaxed
    );
    if (generation != UINT64_MAX) {
        generation += 1;
        atomic_store_explicit(
            &state->decodedTelemetryGeneration,
            generation,
            memory_order_release
        );
    }
    memset(&state->decodedCurrentWindow, 0, sizeof(state->decodedCurrentWindow));
    state->decodedCurrentWindow.generation = generation;
    state->decodedPreviousBlockIsValid = NO;
    state->decodedPreviousBlockFingerprint = 0;
    state->decodedPreviousBlockFrameCount = 0;
    state->decodedPublishedRenderCall = atomic_load_explicit(
        &state->decodedRenderCallCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestRenderSequence,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &state->decodedLatestRenderStatus,
        noErr,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestRequestedFrameCount,
        0,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestRequestedByteCount,
        0,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestReturnedByteCount,
        0,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedLatestBufferContractWasExact,
        false,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &state->decodedCompletedWindows[0].sequence,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &state->decodedCompletedWindows[1].sequence,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &state->decodedPendingWindowFrameCount,
        0,
        memory_order_relaxed
    );
    atomic_flag_clear_explicit(
        &state->decodedTelemetryWriter,
        memory_order_release
    );
}

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
    ASMacDecodedInitializeTelemetry(_state);
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

    // This is the earliest decoded-content boundary: native WebRTC has returned into the exact
    // caller-owned stereo storage and no output-device transform has run yet. Cumulative contract
    // evidence is lock-free and exact. Content analysis retains only fixed-size scalar sums.
    const uint32_t returnedByteCount = audioBufferList.mBuffers[0].mDataByteSize;
    const BOOL bufferContractWasExact = audioBufferList.mNumberBuffers == 1
        && audioBufferList.mBuffers[0].mNumberChannels == ASAudioChannelCount
        && audioBufferList.mBuffers[0].mData == samples
        && returnedByteCount == byteCount;
    const uint64_t renderCall = atomic_fetch_add_explicit(
        &_state->decodedRenderCallCount,
        1,
        memory_order_relaxed
    ) + 1;
    atomic_fetch_add_explicit(
        &_state->decodedRequestedFrameCount,
        frameCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &_state->decodedRequestedByteCount,
        byteCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &_state->decodedReturnedByteCount,
        returnedByteCount,
        memory_order_relaxed
    );
    if (status == noErr) {
        atomic_fetch_add_explicit(
            &_state->decodedNativeSuccessRenderCallCount,
            1,
            memory_order_relaxed
        );
    } else {
        atomic_fetch_add_explicit(
            &_state->decodedNativeFailureRenderCallCount,
            1,
            memory_order_relaxed
        );
    }
    if (bufferContractWasExact) {
        atomic_fetch_add_explicit(
            &_state->decodedExactBufferContractCount,
            1,
            memory_order_relaxed
        );
    } else {
        atomic_fetch_add_explicit(
            &_state->decodedBufferContractMismatchCount,
            1,
            memory_order_relaxed
        );
    }

    ASMacDecodedPublishRenderTelemetry(
        _state,
        renderCall,
        status,
        (uint32_t)frameCount,
        byteCount,
        returnedByteCount,
        bufferContractWasExact,
        status == noErr && bufferContractWasExact ? samples : NULL,
        firstFrame
    );

    atomic_fetch_add_explicit(
        &_state->playoutCallbackCount,
        1,
        memory_order_relaxed
    );
    const BOOL renderSucceeded = status == noErr && bufferContractWasExact;
    if (renderSucceeded) {
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

- (ASMacDecodedPlayoutTelemetrySnapshot)decodedPlayoutTelemetry {
    ASMacDecodedPlayoutTelemetrySnapshot snapshot = {0};
    if (_state == NULL) {
        return snapshot;
    }

    snapshot.playoutGeneration = atomic_load_explicit(
        &_state->decodedTelemetryGeneration,
        memory_order_acquire
    );
    snapshot.renderCallCount = atomic_load_explicit(
        &_state->decodedRenderCallCount,
        memory_order_relaxed
    );
    snapshot.requestedFrameCount = atomic_load_explicit(
        &_state->decodedRequestedFrameCount,
        memory_order_relaxed
    );
    snapshot.requestedByteCount = atomic_load_explicit(
        &_state->decodedRequestedByteCount,
        memory_order_relaxed
    );
    snapshot.returnedByteCount = atomic_load_explicit(
        &_state->decodedReturnedByteCount,
        memory_order_relaxed
    );
    snapshot.nativeSuccessRenderCallCount = atomic_load_explicit(
        &_state->decodedNativeSuccessRenderCallCount,
        memory_order_relaxed
    );
    snapshot.nativeFailureRenderCallCount = atomic_load_explicit(
        &_state->decodedNativeFailureRenderCallCount,
        memory_order_relaxed
    );
    snapshot.exactBufferContractCount = atomic_load_explicit(
        &_state->decodedExactBufferContractCount,
        memory_order_relaxed
    );
    snapshot.bufferContractMismatchCount = atomic_load_explicit(
        &_state->decodedBufferContractMismatchCount,
        memory_order_relaxed
    );
    snapshot.analyzedRenderCallCount = atomic_load_explicit(
        &_state->decodedAnalyzedRenderCallCount,
        memory_order_relaxed
    );
    snapshot.analyzedFrameCount = atomic_load_explicit(
        &_state->decodedAnalyzedFrameCount,
        memory_order_relaxed
    );
    snapshot.analyzedByteCount = atomic_load_explicit(
        &_state->decodedAnalyzedByteCount,
        memory_order_relaxed
    );
    snapshot.droppedTelemetryRenderCallCount = atomic_load_explicit(
        &_state->decodedDroppedTelemetryRenderCallCount,
        memory_order_relaxed
    );
    snapshot.pendingWindowFrameCount = atomic_load_explicit(
        &_state->decodedPendingWindowFrameCount,
        memory_order_relaxed
    );

    for (NSUInteger attempt = 0; attempt < 4; attempt += 1) {
        const uint64_t before = atomic_load_explicit(
            &_state->decodedLatestRenderSequence,
            memory_order_acquire
        );
        if (before == 0) {
            continue;
        }
        const int32_t status = atomic_load_explicit(
            &_state->decodedLatestRenderStatus,
            memory_order_relaxed
        );
        const uint32_t requestedFrames = atomic_load_explicit(
            &_state->decodedLatestRequestedFrameCount,
            memory_order_relaxed
        );
        const uint32_t requestedBytes = atomic_load_explicit(
            &_state->decodedLatestRequestedByteCount,
            memory_order_relaxed
        );
        const uint32_t returnedBytes = atomic_load_explicit(
            &_state->decodedLatestReturnedByteCount,
            memory_order_relaxed
        );
        const bool contractWasExact = atomic_load_explicit(
            &_state->decodedLatestBufferContractWasExact,
            memory_order_relaxed
        );
        const uint64_t after = atomic_load_explicit(
            &_state->decodedLatestRenderSequence,
            memory_order_acquire
        );
        if (before == after) {
            snapshot.latestRenderCall = after;
            snapshot.latestRenderStatus = status;
            snapshot.latestRequestedFrameCount = requestedFrames;
            snapshot.latestRequestedByteCount = requestedBytes;
            snapshot.latestReturnedByteCount = returnedBytes;
            snapshot.latestBufferContractWasExact = contractWasExact;
            break;
        }
    }

    ASMacDecodedPlayoutPublishedWindow published = {0};
    if (!ASMacDecodedReadLatestCompletedWindow(_state, &published)
        || published.scalars.generation != snapshot.playoutGeneration
        || published.scalars.frameCount == 0) {
        return snapshot;
    }

    const ASMacDecodedPlayoutWindowScalars *window = &published.scalars;
    const double frameCount = (double)window->frameCount;
    const double fullScale = 32768.0;
    const double fullScaleSquared = fullScale * fullScale;
    snapshot.hasCompletedWindow = true;
    snapshot.completedWindowSequence = published.sequence;
    snapshot.completedWindowGeneration = window->generation;
    snapshot.completedWindowFirstRenderCall = window->firstRenderCall;
    snapshot.completedWindowLastRenderCall = window->lastRenderCall;
    snapshot.completedWindowRenderCallCount = window->renderCallCount;
    snapshot.completedWindowFrameCount = window->frameCount;
    snapshot.completedWindowByteCount = window->byteCount;
    snapshot.completedWindowSourceStartFrame = window->sourceStartFrame;
    snapshot.completedWindowSourceEndFrame = window->sourceEndFrame;
    snapshot.completedWindowFingerprint = window->fingerprint;
    snapshot.completedWindowDurationSeconds = frameCount / ASAudioSampleRate;
    snapshot.leftRMS = sqrt(window->leftSquareSum / frameCount) / fullScale;
    snapshot.rightRMS = sqrt(window->rightSquareSum / frameCount) / fullScale;
    snapshot.leftPeak = (double)window->leftPeakMagnitude / fullScale;
    snapshot.rightPeak = (double)window->rightPeakMagnitude / fullScale;
    snapshot.leftRMSDecibelsFS = snapshot.leftRMS > 0
        ? 20 * log10(snapshot.leftRMS)
        : -INFINITY;
    snapshot.rightRMSDecibelsFS = snapshot.rightRMS > 0
        ? 20 * log10(snapshot.rightRMS)
        : -INFINITY;
    snapshot.leftPeakDecibelsFS = snapshot.leftPeak > 0
        ? 20 * log10(snapshot.leftPeak)
        : -INFINITY;
    snapshot.rightPeakDecibelsFS = snapshot.rightPeak > 0
        ? 20 * log10(snapshot.rightPeak)
        : -INFINITY;
    snapshot.leftDC = ((double)window->leftSum / frameCount) / fullScale;
    snapshot.rightDC = ((double)window->rightSum / frameCount) / fullScale;
    snapshot.leftZeroSampleCount = window->leftZeroSampleCount;
    snapshot.rightZeroSampleCount = window->rightZeroSampleCount;
    snapshot.leftZeroFraction = (double)window->leftZeroSampleCount / frameCount;
    snapshot.rightZeroFraction = (double)window->rightZeroSampleCount / frameCount;
    snapshot.leftClippedSampleCount = window->leftClippedSampleCount;
    snapshot.rightClippedSampleCount = window->rightClippedSampleCount;
    snapshot.leftClippingFraction =
        (double)window->leftClippedSampleCount / frameCount;
    snapshot.rightClippingFraction =
        (double)window->rightClippedSampleCount / frameCount;
    const double centeredLeftPower = fmax(
        0,
        window->leftSquareSum
            - ((double)window->leftSum * window->leftSum) / frameCount
    );
    const double centeredRightPower = fmax(
        0,
        window->rightSquareSum
            - ((double)window->rightSum * window->rightSum) / frameCount
    );
    if (centeredLeftPower > 0 && centeredRightPower > 0) {
        const double centeredCrossPower = window->crossSum
            - ((double)window->leftSum * window->rightSum) / frameCount;
        snapshot.leftRightCorrelationIsValid = true;
        snapshot.leftRightCorrelation = centeredCrossPower
            / sqrt(centeredLeftPower * centeredRightPower);
        snapshot.leftRightCorrelation = fmax(
            -1,
            fmin(1, snapshot.leftRightCorrelation)
        );
    }
    snapshot.sumPower = window->sumSquareSum
        / (frameCount * 4 * fullScaleSquared);
    snapshot.differencePower = window->differenceSquareSum
        / (frameCount * 4 * fullScaleSquared);
    snapshot.oneSidedFrameCount = window->oneSidedFrameCount;
    snapshot.oneSidedFraction =
        (double)window->oneSidedFrameCount / frameCount;
    snapshot.windowIsAllZero = window->leftSquareSum == 0
        && window->rightSquareSum == 0;
    snapshot.windowIsLeftOnly = window->leftActiveFrameCount > 0
        && window->rightActiveFrameCount == 0;
    snapshot.windowIsRightOnly = window->leftActiveFrameCount == 0
        && window->rightActiveFrameCount > 0;
    snapshot.allZeroBlockCount = window->allZeroBlockCount;
    snapshot.leftOnlyBlockCount = window->leftOnlyBlockCount;
    snapshot.rightOnlyBlockCount = window->rightOnlyBlockCount;
    snapshot.frozenBlockCount = window->frozenBlockCount;
    snapshot.longestFrozenBlockRun = window->longestFrozenBlockRun;
    return snapshot;
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
    ASMacDecodedResetTelemetryGeneration(_state);
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

- (void)holdDecodedTelemetryReadsForTesting {
    if (_state == NULL) {
        return;
    }
    atomic_store_explicit(
        &_state->holdDecodedTelemetryReadForTesting,
        true,
        memory_order_release
    );
}

- (void)releaseDecodedTelemetryReadsForTesting {
    if (_state == NULL) {
        return;
    }
    atomic_store_explicit(
        &_state->decodedTelemetryReadIsHeldForTesting,
        false,
        memory_order_release
    );
}

- (BOOL)decodedTelemetryReadIsHeldForTesting {
    return _state != NULL
        && atomic_load_explicit(
            &_state->decodedTelemetryReadIsHeldForTesting,
            memory_order_acquire
        );
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
