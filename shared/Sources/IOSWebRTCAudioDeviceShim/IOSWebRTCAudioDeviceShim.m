#import "IOSWebRTCAudioDeviceShim.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#include <limits.h>
#include <math.h>
#include <sched.h>
#include <stdint.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>

// The custom iOS device keeps playback/output available at all times. Microphone/input is activated
// only after authorization and only while recording is requested. Native lifecycle work stays on
// WebRTC's ADM queue; realtime callbacks must not allocate or dispatch application work.
static const double ASSampleRate = 48000.0;
static const NSTimeInterval ASIOBufferDuration = 0.010;
static const UInt32 ASOutputChannelCount = 2;
static const UInt32 ASInputChannelCount = 1;
static const uint64_t ASMicrophoneRouteConvergenceTimeoutNanoseconds =
    1000000000;
static const uint64_t ASExpectedMicrophoneRouteChangeLifetimeNanoseconds =
    3000000000;
// RemoteIO may return from AudioOutputUnitStart before AVAudioSession delivers a coalesced
// reason-8 notification caused by that exact start. Keep one transaction-bound provenance claim
// for the full native convergence interval. Publication no longer waits on, or derives correctness
// from, an arbitrary quiet period. The explicit state prevents a claim consumed while the route
// transaction is still Starting from becoming replayable after the transaction commits.
static const uint64_t ASRemoteIOStartSettlementLifetimeNanoseconds =
    1000000000;
// The release route accepts at most a 20 ms IO buffer. A healthy 10 ms RemoteIO cadence therefore
// gets ordinary scheduler tolerance, but a 30 ms callback separation (one whole preferred buffer
// late) must fail. This catches recurring short dropouts instead of only catastrophic stalls.
static const uint64_t ASCallbackGapViolationThresholdNanoseconds = 25000000;
// Both levels of the physical oracle's coded low/high-band challenge remain above these thresholds
// after conservative output gain. Requiring density and mean magnitude prevents callback clocks,
// dither, or isolated impulses from masquerading as audible program content.
static const uint64_t ASNearSilenceMinimumMeanMagnitude = 256;
static const uint64_t ASNearSilenceMinimumNonzeroPercent = 90;
// The physical challenge deliberately changes level every 500 ms. A >40% adjacent-callback
// change records that ordered envelope transition; rapid gain pumping records far too many, while
// a frozen/repeated callback records none. The metric is observational outside the release gate.
static const uint64_t ASEnvelopeTransitionRatioPercent = 140;
// A clean sine has a mean-absolute/peak ratio of about 64%. These intentionally broad bounds
// admit callbacks that straddle the physical challenge's 3:1 level transitions while rejecting
// sparse impulses and flat/square PCM. The release oracle ratio-gates this cumulative evidence;
// one unusual callback is diagnostic evidence, not an immediate playback failure.
static const uint64_t ASWaveformShapeMinimumMeanToPeakPercent = 18;
static const uint64_t ASWaveformShapeMaximumMeanToPeakPercent = 88;
static const uint64_t ASWaveformShapeMinimumSampleCount = 16;
// For any sinusoid, a legitimate sample-to-sample boundary step is at most about 1.57 times its
// mean internal derivative. A 1.75x allowance tolerates quantization and callback sizing, while
// still detecting every reset of the 997/1499 Hz 10 ms challenge blocks.
static const uint64_t ASBoundaryJumpToMeanDerivativePercent = 175;

__attribute__((noreturn))
static void ASFailRealtimeGateInvariant(void);

// MARK: - Exact reason-8 notification arbitration

@interface ASRouteConfigurationChangeArbitrationWaiter : NSObject
@property(nonatomic) NSUInteger identifier;
@property(nonatomic) uint64_t observerIdentifier;
@property(nonatomic, copy) ASIOSRouteConfigurationChangeDispositionHandler handler;
@end

@implementation ASRouteConfigurationChangeArbitrationWaiter
@end

@interface ASRouteConfigurationChangeArbitrationRecord : NSObject
@property(nonatomic, strong) NSNotification *notification;
@property(nonatomic) BOOL nativeResolverBound;
@property(nonatomic) uintptr_t nativeResolverIdentity;
@property(nonatomic) uint64_t nativeResolverEpoch;
@property(nonatomic) BOOL resolved;
@property(nonatomic) ASIOSRouteConfigurationChangeDisposition disposition;
@property(nonatomic, strong)
    NSMutableArray<ASRouteConfigurationChangeArbitrationWaiter *> *waiters;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *eligibleObserverIdentifiers;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *pendingObserverIdentifiers;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *completedObserverIdentifiers;
@end

@implementation ASRouteConfigurationChangeArbitrationRecord
@end

static dispatch_queue_t ASRouteConfigurationChangeArbitrationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "org.opensteamer.audio.route-configuration-arbitration",
            DISPATCH_QUEUE_SERIAL
        );
    });
    return queue;
}

static NSMutableDictionary<NSValue *, ASRouteConfigurationChangeArbitrationRecord *> *
ASRouteConfigurationChangeArbitrationRecords(void) {
    static NSMutableDictionary<
        NSValue *, ASRouteConfigurationChangeArbitrationRecord *> *records;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        records = [NSMutableDictionary dictionary];
    });
    return records;
}

static NSHashTable<NSNotification *> *
ASTerminalRouteConfigurationChangeNotifications(void) {
    static NSHashTable<NSNotification *> *notifications;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        notifications = [[NSHashTable alloc] initWithOptions:
            NSPointerFunctionsWeakMemory
                | NSPointerFunctionsObjectPointerPersonality
                                                    capacity:0];
    });
    return notifications;
}

static NSMutableSet<NSNumber *> *
ASActiveRouteConfigurationChangeObserverIdentifiers(void) {
    static NSMutableSet<NSNumber *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = [NSMutableSet set];
    });
    return identifiers;
}

// These values are confined to ASRouteConfigurationChangeArbitrationQueue.
static uint64_t ASNextRouteConfigurationChangeObserverIdentifier = 0;
static uint64_t ASNextRouteConfigurationChangeResolverEpoch = 0;
static uintptr_t ASActiveRouteConfigurationChangeResolverIdentity = 0;
static uint64_t ASActiveRouteConfigurationChangeResolverEpoch = 0;

typedef struct ASRouteConfigurationChangeResolverToken {
    uintptr_t identity;
    uint64_t epoch;
} ASRouteConfigurationChangeResolverToken;

static const ASRouteConfigurationChangeResolverToken
ASInvalidRouteConfigurationChangeResolverToken = {0, 0};

static NSValue *ASRouteConfigurationChangeNotificationKey(
    NSNotification *notification
) {
    return [NSValue valueWithPointer:(__bridge const void *)notification];
}

static dispatch_queue_t ASRouteConfigurationChangeDispositionDeliveryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "org.opensteamer.audio.route-configuration-disposition-delivery",
            DISPATCH_QUEUE_SERIAL
        );
    });
    return queue;
}

static void ASDispatchRouteConfigurationChangeDisposition(
    ASIOSRouteConfigurationChangeDispositionHandler handler,
    ASIOSRouteConfigurationChangeDisposition disposition
) {
    if (handler == nil) {
        return;
    }
    dispatch_async(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{
            handler(disposition);
        }
    );
}

static ASRouteConfigurationChangeArbitrationRecord *
ASRouteConfigurationChangeRecord(
    NSMutableDictionary<NSValue *, ASRouteConfigurationChangeArbitrationRecord *> *records,
    NSValue *key,
    NSNotification *notification,
    BOOL createIfMissing
) {
    ASRouteConfigurationChangeArbitrationRecord *record = records[key];
    if (record == nil && createIfMissing) {
        if ([ASTerminalRouteConfigurationChangeNotifications()
                containsObject:notification]) {
            return nil;
        }
        record = [[ASRouteConfigurationChangeArbitrationRecord alloc] init];
        record.notification = notification;
        record.waiters = [NSMutableArray array];
        record.eligibleObserverIdentifiers = [NSMutableSet set];
        record.pendingObserverIdentifiers = [NSMutableSet set];
        record.completedObserverIdentifiers = [NSMutableSet set];
        records[key] = record;
    } else if (record != nil && record.notification != notification) {
        // A retained notification makes pointer reuse impossible. Treat any violation as a
        // programming invariant instead of letting one event borrow another's disposition.
        ASFailRealtimeGateInvariant();
    }
    return record;
}

static void ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
    NSMutableDictionary<NSValue *, ASRouteConfigurationChangeArbitrationRecord *> *records,
    NSValue *key,
    ASRouteConfigurationChangeArbitrationRecord *record
) {
    [records removeObjectForKey:key];
    [ASTerminalRouteConfigurationChangeNotifications()
        addObject:record.notification];
}

static uint64_t ASAllocateRouteConfigurationChangeObserverIdentifier(void) {
    dispatch_queue_t queue = ASRouteConfigurationChangeArbitrationQueue();
    __block uint64_t identifier = 0;
    dispatch_sync(queue, ^{
        ASNextRouteConfigurationChangeObserverIdentifier += 1;
        if (ASNextRouteConfigurationChangeObserverIdentifier == 0) {
            ASNextRouteConfigurationChangeObserverIdentifier = 1;
        }
        identifier = ASNextRouteConfigurationChangeObserverIdentifier;
    });
    return identifier;
}

static void ASActivateRouteConfigurationChangeObserverIdentifier(
    uint64_t observerIdentifier
) {
    if (observerIdentifier == 0) {
        return;
    }
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        [ASActiveRouteConfigurationChangeObserverIdentifiers()
            addObject:@(observerIdentifier)];
    });
}

static void ASInvalidateRouteConfigurationChangeObserverIdentifier(
    uint64_t observerIdentifier
) {
    if (observerIdentifier == 0) {
        return;
    }
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        NSNumber *identifier = @(observerIdentifier);
        NSMutableSet<NSNumber *> *activeIdentifiers =
            ASActiveRouteConfigurationChangeObserverIdentifiers();
        [activeIdentifiers removeObject:identifier];

        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        for (NSValue *key in [records.allKeys copy]) {
            ASRouteConfigurationChangeArbitrationRecord *record = records[key];
            NSIndexSet *retiredWaiterIndexes = [record.waiters
                indexesOfObjectsPassingTest:^BOOL(
                    ASRouteConfigurationChangeArbitrationWaiter *waiter,
                    __unused NSUInteger index,
                    __unused BOOL *stop
                ) {
                    return waiter.observerIdentifier == observerIdentifier;
                }];
            [record.waiters removeObjectsAtIndexes:retiredWaiterIndexes];
            [record.eligibleObserverIdentifiers removeObject:identifier];
            [record.pendingObserverIdentifiers removeObject:identifier];
            [record.completedObserverIdentifiers removeObject:identifier];
            BOOL hasNoConsumer = record.waiters.count == 0
                && record.eligibleObserverIdentifiers.count == 0
                && record.pendingObserverIdentifiers.count == 0;
            if (hasNoConsumer) {
                ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
                    records,
                    key,
                    record
                );
            }
        }
    });
}

static void ASConvertRetiredResolverRecordsToFallbackWhileHoldingQueue(
    uintptr_t resolverIdentity,
    uint64_t resolverEpoch
) {
    if (resolverIdentity == 0 || resolverEpoch == 0) {
        return;
    }
    NSMutableSet<NSNumber *> *activeIdentifiers =
        ASActiveRouteConfigurationChangeObserverIdentifiers();
    NSMutableDictionary *records =
        ASRouteConfigurationChangeArbitrationRecords();
    for (NSValue *key in [records.allKeys copy]) {
        ASRouteConfigurationChangeArbitrationRecord *record = records[key];
        if (!record.nativeResolverBound
            || record.nativeResolverIdentity != resolverIdentity
            || record.nativeResolverEpoch != resolverEpoch) {
            continue;
        }

        [record.eligibleObserverIdentifiers intersectSet:activeIdentifiers];
        if (!record.resolved) {
            record.pendingObserverIdentifiers =
                [record.eligibleObserverIdentifiers mutableCopy];
            for (ASRouteConfigurationChangeArbitrationWaiter *waiter
                    in [record.waiters copy]) {
                NSNumber *identifier = @(waiter.observerIdentifier);
                if ([record.pendingObserverIdentifiers containsObject:identifier]) {
                    [record.pendingObserverIdentifiers removeObject:identifier];
                    [record.completedObserverIdentifiers addObject:identifier];
                    ASDispatchRouteConfigurationChangeDisposition(
                        waiter.handler,
                        ASIOSRouteConfigurationChangeDispositionTimedOut
                    );
                }
            }
            [record.waiters removeAllObjects];
            record.resolved = YES;
            record.disposition =
                ASIOSRouteConfigurationChangeDispositionTimedOut;
        } else {
            [record.pendingObserverIdentifiers intersectSet:activeIdentifiers];
        }
        record.nativeResolverBound = NO;
        record.nativeResolverIdentity = 0;
        record.nativeResolverEpoch = 0;
        if (record.pendingObserverIdentifiers.count == 0) {
            ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
                records,
                key,
                record
            );
        }
    }
}

static uint64_t ASRegisterRouteConfigurationChangeResolver(
    uintptr_t resolverIdentity
) {
    if (resolverIdentity == 0) {
        return 0;
    }
    __block uint64_t resolverEpoch = 0;
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        ASConvertRetiredResolverRecordsToFallbackWhileHoldingQueue(
            ASActiveRouteConfigurationChangeResolverIdentity,
            ASActiveRouteConfigurationChangeResolverEpoch
        );
        ASNextRouteConfigurationChangeResolverEpoch += 1;
        if (ASNextRouteConfigurationChangeResolverEpoch == 0) {
            ASNextRouteConfigurationChangeResolverEpoch = 1;
        }
        ASActiveRouteConfigurationChangeResolverIdentity = resolverIdentity;
        ASActiveRouteConfigurationChangeResolverEpoch =
            ASNextRouteConfigurationChangeResolverEpoch;
        resolverEpoch = ASActiveRouteConfigurationChangeResolverEpoch;
    });
    return resolverEpoch;
}

static void ASRetireRouteConfigurationChangeResolver(
    uintptr_t resolverIdentity,
    uint64_t resolverEpoch
) {
    if (resolverIdentity == 0 || resolverEpoch == 0) {
        return;
    }
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        if (ASActiveRouteConfigurationChangeResolverIdentity
                != resolverIdentity
            || ASActiveRouteConfigurationChangeResolverEpoch
                != resolverEpoch) {
            return;
        }
        ASConvertRetiredResolverRecordsToFallbackWhileHoldingQueue(
            resolverIdentity,
            resolverEpoch
        );
        ASActiveRouteConfigurationChangeResolverIdentity = 0;
        ASActiveRouteConfigurationChangeResolverEpoch = 0;
    });
}

static ASRouteConfigurationChangeResolverToken
ASBeginRouteConfigurationChangeResolution(
    NSNotification *notification,
    uintptr_t resolverIdentity
) {
    if (notification == nil || resolverIdentity == 0) {
        return ASInvalidRouteConfigurationChangeResolverToken;
    }
    __block ASRouteConfigurationChangeResolverToken token =
        ASInvalidRouteConfigurationChangeResolverToken;
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        if (ASActiveRouteConfigurationChangeResolverIdentity
                != resolverIdentity
            || ASActiveRouteConfigurationChangeResolverEpoch == 0) {
            return;
        }
        token.identity = resolverIdentity;
        token.epoch = ASActiveRouteConfigurationChangeResolverEpoch;

        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        NSValue *key =
            ASRouteConfigurationChangeNotificationKey(notification);
        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeRecord(
                records,
                key,
                notification,
                YES
            );
        if (record == nil || record.resolved) {
            return;
        }
        record.nativeResolverBound = YES;
        record.nativeResolverIdentity = token.identity;
        record.nativeResolverEpoch = token.epoch;
        record.eligibleObserverIdentifiers =
            [ASActiveRouteConfigurationChangeObserverIdentifiers()
                mutableCopy];
        [record.eligibleObserverIdentifiers
            minusSet:record.completedObserverIdentifiers];
        NSIndexSet *ineligibleWaiterIndexes = [record.waiters
            indexesOfObjectsPassingTest:^BOOL(
                ASRouteConfigurationChangeArbitrationWaiter *waiter,
                __unused NSUInteger index,
                __unused BOOL *stop
            ) {
                return ![record.eligibleObserverIdentifiers
                    containsObject:@(waiter.observerIdentifier)];
            }];
        [record.waiters removeObjectsAtIndexes:ineligibleWaiterIndexes];
        if (record.eligibleObserverIdentifiers.count == 0
            && record.waiters.count == 0) {
            ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
                records,
                key,
                record
            );
        }
    });
    return token;
}

static ASIOSRouteConfigurationChangeDispositionHandler
ASCompleteRouteConfigurationChangeWaiterTimeoutWhileHoldingQueue(
    NSNotification *notification,
    NSValue *key,
    uint64_t observerIdentifier,
    NSUInteger waiterIdentifier
);

static void ASAwaitRouteConfigurationChangeDisposition(
    NSNotification *notification,
    uint64_t observerIdentifier,
    NSTimeInterval timeout,
    ASIOSRouteConfigurationChangeDispositionHandler handler
) {
    if (notification == nil || observerIdentifier == 0 || handler == nil) {
        ASDispatchRouteConfigurationChangeDisposition(
            handler,
            ASIOSRouteConfigurationChangeDispositionUninitialized
        );
        return;
    }

    NSTimeInterval boundedTimeout = isfinite(timeout) && timeout > 0
        ? MIN(timeout, 5.0)
        : 0.25;
    __block ASIOSRouteConfigurationChangeDisposition immediateDisposition =
        ASIOSRouteConfigurationChangeDispositionTimedOut;
    __block BOOL resolvedImmediately = NO;
    __block BOOL ignored = NO;
    __block NSUInteger waiterIdentifier = 0;
    dispatch_queue_t queue = ASRouteConfigurationChangeArbitrationQueue();
    NSValue *key = ASRouteConfigurationChangeNotificationKey(notification);
    dispatch_sync(queue, ^{
        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        NSNumber *observerNumber = @(observerIdentifier);
        if (![ASActiveRouteConfigurationChangeObserverIdentifiers()
                containsObject:observerNumber]) {
            ignored = YES;
            return;
        }

        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeRecord(
                records,
                key,
                notification,
                YES
            );

        if (record == nil) {
            ignored = YES;
            return;
        }

        if (record.resolved) {
            if (![record.pendingObserverIdentifiers
                    containsObject:observerNumber]) {
                ignored = YES;
                return;
            }
            [record.pendingObserverIdentifiers removeObject:observerNumber];
            [record.completedObserverIdentifiers addObject:observerNumber];
            resolvedImmediately = YES;
            immediateDisposition = record.disposition;
            if (record.pendingObserverIdentifiers.count == 0) {
                ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
                    records,
                    key,
                    record
                );
            }
            return;
        }

        if (record.nativeResolverBound
            && ![record.eligibleObserverIdentifiers
                containsObject:observerNumber]) {
            ignored = YES;
            return;
        }

        static NSUInteger nextWaiterIdentifier = 0;
        nextWaiterIdentifier += 1;
        if (nextWaiterIdentifier == 0) {
            nextWaiterIdentifier = 1;
        }
        waiterIdentifier = nextWaiterIdentifier;
        ASRouteConfigurationChangeArbitrationWaiter *waiter =
            [[ASRouteConfigurationChangeArbitrationWaiter alloc] init];
        waiter.identifier = waiterIdentifier;
        waiter.observerIdentifier = observerIdentifier;
        waiter.handler = handler;
        [record.waiters addObject:waiter];
    });

    if (ignored) {
        return;
    }

    if (resolvedImmediately) {
        ASDispatchRouteConfigurationChangeDisposition(
            handler,
            immediateDisposition
        );
        return;
    }

    uint64_t timeoutNanoseconds = (uint64_t)(boundedTimeout * NSEC_PER_SEC);
    int64_t dispatchDelay = timeoutNanoseconds > (uint64_t)INT64_MAX
        ? INT64_MAX
        : (int64_t)timeoutNanoseconds;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, dispatchDelay),
        queue,
        ^{
            ASIOSRouteConfigurationChangeDispositionHandler timeoutHandler =
                ASCompleteRouteConfigurationChangeWaiterTimeoutWhileHoldingQueue(
                    notification,
                    key,
                    observerIdentifier,
                    waiterIdentifier
                );
            ASDispatchRouteConfigurationChangeDisposition(
                timeoutHandler,
                ASIOSRouteConfigurationChangeDispositionTimedOut
            );
        }
    );
}

static ASIOSRouteConfigurationChangeDispositionHandler
ASCompleteRouteConfigurationChangeWaiterTimeoutWhileHoldingQueue(
    NSNotification *notification,
    NSValue *key,
    uint64_t observerIdentifier,
    NSUInteger waiterIdentifier
) {
    NSMutableDictionary *records =
        ASRouteConfigurationChangeArbitrationRecords();
    ASRouteConfigurationChangeArbitrationRecord *record = records[key];
    if (record == nil || record.notification != notification
        || record.resolved) {
        return nil;
    }
    NSUInteger index = [record.waiters
        indexOfObjectPassingTest:^BOOL(
            ASRouteConfigurationChangeArbitrationWaiter *waiter,
            __unused NSUInteger index,
            __unused BOOL *stop
        ) {
            return waiter.identifier == waiterIdentifier;
        }];
    if (index == NSNotFound) {
        return nil;
    }
    ASIOSRouteConfigurationChangeDispositionHandler timeoutHandler =
        record.waiters[index].handler;
    NSNumber *observerNumber = @(observerIdentifier);
    [record.waiters removeObjectAtIndex:index];
    [record.eligibleObserverIdentifiers removeObject:observerNumber];
    [record.pendingObserverIdentifiers removeObject:observerNumber];
    [record.completedObserverIdentifiers addObject:observerNumber];
    if (record.waiters.count == 0
        && record.eligibleObserverIdentifiers.count == 0
        && record.pendingObserverIdentifiers.count == 0) {
        ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
            records,
            key,
            record
        );
    }
    return timeoutHandler;
}

static NSArray<ASRouteConfigurationChangeArbitrationWaiter *> *
ASResolveRouteConfigurationChangeRecordWhileHoldingQueue(
    NSMutableDictionary<NSValue *, ASRouteConfigurationChangeArbitrationRecord *> *records,
    NSValue *key,
    ASRouteConfigurationChangeArbitrationRecord *record,
    ASIOSRouteConfigurationChangeDisposition disposition
) {
    record.resolved = YES;
    record.disposition = disposition;
    record.pendingObserverIdentifiers =
        [record.eligibleObserverIdentifiers mutableCopy];
    [record.pendingObserverIdentifiers
        intersectSet:ASActiveRouteConfigurationChangeObserverIdentifiers()];
    NSMutableArray *eligibleWaiters = [NSMutableArray array];
    for (ASRouteConfigurationChangeArbitrationWaiter *waiter
            in record.waiters) {
        NSNumber *identifier = @(waiter.observerIdentifier);
        if ([record.pendingObserverIdentifiers containsObject:identifier]) {
            [eligibleWaiters addObject:waiter];
            [record.pendingObserverIdentifiers removeObject:identifier];
            [record.completedObserverIdentifiers addObject:identifier];
        }
    }
    [record.waiters removeAllObjects];
    if (record.pendingObserverIdentifiers.count == 0) {
        ASRemoveRouteConfigurationChangeRecordWhileHoldingQueue(
            records,
            key,
            record
        );
    }
    return [eligibleWaiters copy];
}

static void ASResolveRouteConfigurationChangeDisposition(
    NSNotification *notification,
    ASRouteConfigurationChangeResolverToken resolverToken,
    ASIOSRouteConfigurationChangeDisposition disposition
) {
    if (notification == nil || resolverToken.identity == 0
        || resolverToken.epoch == 0) {
        return;
    }

    dispatch_queue_t queue = ASRouteConfigurationChangeArbitrationQueue();
    NSValue *key = ASRouteConfigurationChangeNotificationKey(notification);
    __block NSArray<ASRouteConfigurationChangeArbitrationWaiter *> *waiters = nil;
    dispatch_sync(queue, ^{
        if (ASActiveRouteConfigurationChangeResolverIdentity
                != resolverToken.identity
            || ASActiveRouteConfigurationChangeResolverEpoch
                != resolverToken.epoch) {
            return;
        }
        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeRecord(
                records,
                key,
                notification,
                NO
            );
        if (record == nil || record.resolved
            || !record.nativeResolverBound
            || record.nativeResolverIdentity != resolverToken.identity
            || record.nativeResolverEpoch != resolverToken.epoch) {
            return;
        }
        waiters = ASResolveRouteConfigurationChangeRecordWhileHoldingQueue(
            records,
            key,
            record,
            disposition
        );
    });

    for (ASRouteConfigurationChangeArbitrationWaiter *waiter in waiters) {
        ASDispatchRouteConfigurationChangeDisposition(
            waiter.handler,
            disposition
        );
    }

}

#if DEBUG
static const uintptr_t ASDebugRouteConfigurationChangeResolverIdentity =
    UINTPTR_MAX;
static const uint64_t ASDebugRouteConfigurationChangeResolverEpoch =
    UINT64_MAX;

static void ASDebugBeginRouteConfigurationChangeResolution(
    NSNotification *notification
) {
    if (notification == nil) {
        return;
    }
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        NSValue *key =
            ASRouteConfigurationChangeNotificationKey(notification);
        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeRecord(
                records,
                key,
                notification,
                YES
            );
        if (record == nil || record.resolved) {
            return;
        }
        record.nativeResolverBound = YES;
        record.nativeResolverIdentity =
            ASDebugRouteConfigurationChangeResolverIdentity;
        record.nativeResolverEpoch =
            ASDebugRouteConfigurationChangeResolverEpoch;
        record.eligibleObserverIdentifiers =
            [ASActiveRouteConfigurationChangeObserverIdentifiers()
                mutableCopy];
        [record.eligibleObserverIdentifiers
            minusSet:record.completedObserverIdentifiers];
    });
}

static void ASDebugResolveRouteConfigurationChangeDisposition(
    NSNotification *notification,
    ASIOSRouteConfigurationChangeDisposition disposition
) {
    if (notification == nil) {
        return;
    }
    __block NSArray<ASRouteConfigurationChangeArbitrationWaiter *> *waiters = nil;
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        NSMutableDictionary *records =
            ASRouteConfigurationChangeArbitrationRecords();
        NSValue *key =
            ASRouteConfigurationChangeNotificationKey(notification);
        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeRecord(
                records,
                key,
                notification,
                NO
            );
        if (record == nil || record.resolved
            || !record.nativeResolverBound
            || record.nativeResolverIdentity
                != ASDebugRouteConfigurationChangeResolverIdentity
            || record.nativeResolverEpoch
                != ASDebugRouteConfigurationChangeResolverEpoch) {
            return;
        }
        waiters = ASResolveRouteConfigurationChangeRecordWhileHoldingQueue(
            records,
            key,
            record,
            disposition
        );
    });
    for (ASRouteConfigurationChangeArbitrationWaiter *waiter in waiters) {
        ASDispatchRouteConfigurationChangeDisposition(
            waiter.handler,
            disposition
        );
    }
}

static void ASDebugReplaceRouteConfigurationChangeResolver(void) {
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        ASConvertRetiredResolverRecordsToFallbackWhileHoldingQueue(
            ASDebugRouteConfigurationChangeResolverIdentity,
            ASDebugRouteConfigurationChangeResolverEpoch
        );
    });
}

static BOOL ASDebugTimeoutRouteConfigurationChangeDisposition(
    NSNotification *notification,
    uint64_t observerIdentifier
) {
    if (notification == nil || observerIdentifier == 0) {
        return NO;
    }
    __block ASIOSRouteConfigurationChangeDispositionHandler timeoutHandler = nil;
    NSValue *key = ASRouteConfigurationChangeNotificationKey(notification);
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        ASRouteConfigurationChangeArbitrationRecord *record =
            ASRouteConfigurationChangeArbitrationRecords()[key];
        if (record == nil || record.resolved) {
            return;
        }
        NSUInteger index = [record.waiters
            indexOfObjectPassingTest:^BOOL(
                ASRouteConfigurationChangeArbitrationWaiter *waiter,
                __unused NSUInteger index,
                __unused BOOL *stop
            ) {
                return waiter.observerIdentifier == observerIdentifier;
            }];
        if (index == NSNotFound) {
            return;
        }
        timeoutHandler =
            ASCompleteRouteConfigurationChangeWaiterTimeoutWhileHoldingQueue(
                notification,
                key,
                observerIdentifier,
                record.waiters[index].identifier
            );
    });
    ASDispatchRouteConfigurationChangeDisposition(
        timeoutHandler,
        ASIOSRouteConfigurationChangeDispositionTimedOut
    );
    return timeoutHandler != nil;
}

static NSUInteger ASDebugRouteConfigurationChangeArbitrationRecordCount(void) {
    __block NSUInteger recordCount = 0;
    dispatch_sync(ASRouteConfigurationChangeArbitrationQueue(), ^{
        recordCount = ASRouteConfigurationChangeArbitrationRecords().count;
    });
    return recordCount;
}
#endif

@implementation ASIOSRouteConfigurationChangeObserver {
    id _notificationToken;
    ASIOSRouteConfigurationChangeObservationHandler _handler;
    NSTimeInterval _timeout;
    uint64_t _observerIdentifier;
    uint64_t _generation;
    uint64_t _notificationSequence;
    uint64_t _audioPolicyEpoch;
    BOOL _invalidated;
}

- (instancetype)initWithTimeout:(NSTimeInterval)timeout
                         handler:
                             (ASIOSRouteConfigurationChangeObservationHandler)handler {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _handler = [handler copy];
    _timeout = isfinite(timeout) && timeout > 0 ? MIN(timeout, 5.0) : 0.25;
    _observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(
        _observerIdentifier
    );
    _generation = 1;
    __weak ASIOSRouteConfigurationChangeObserver *weakSelf = self;
    _notificationToken = [NSNotificationCenter.defaultCenter
        addObserverForName:AVAudioSessionRouteChangeNotification
                    object:AVAudioSession.sharedInstance
                     queue:nil
                usingBlock:^(NSNotification *notification) {
                    NSNumber *reasonValue =
                        notification.userInfo[AVAudioSessionRouteChangeReasonKey];
                    if (reasonValue.unsignedIntegerValue
                        != AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
                        return;
                    }
                    ASIOSRouteConfigurationChangeObserver *self = weakSelf;
                    if (self == nil) {
                        return;
                    }
                    __block uint64_t generation = 0;
                    __block uint64_t observationIdentifier = 0;
                    __block NSTimeInterval observationTimeout = 0;
                    __block uint64_t notificationSequence = 0;
                    __block uint64_t audioPolicyEpoch = 0;
                    @synchronized (self) {
                        if (!self->_invalidated) {
                            self->_notificationSequence += 1;
                            if (self->_notificationSequence == 0) {
                                self->_notificationSequence = 1;
                            }
                            generation = self->_generation;
                            observationIdentifier =
                                self->_observerIdentifier;
                            observationTimeout = self->_timeout;
                            notificationSequence =
                                self->_notificationSequence;
                            audioPolicyEpoch =
                                self->_audioPolicyEpoch;
                        }
                    }
                    if (generation == 0) {
                        return;
                    }
                    ASAwaitRouteConfigurationChangeDisposition(
                        notification,
                        observationIdentifier,
                        observationTimeout,
                        ^(ASIOSRouteConfigurationChangeDisposition disposition) {
                            ASIOSRouteConfigurationChangeObserver *self = weakSelf;
                            if (self == nil) {
                                return;
                            }
                            __block ASIOSRouteConfigurationChangeObservationHandler
                                handler = nil;
                            @synchronized (self) {
                                if (!self->_invalidated
                                    && self->_generation == generation
                                    && self->_handler != nil) {
                                    handler = [self->_handler copy];
                                }
                            }
                            if (handler != nil) {
                                handler(
                                    disposition,
                                    notificationSequence,
                                    audioPolicyEpoch
                                );
                            }
                        }
                    );
                }];
    return self;
}

- (uint64_t)latestNotificationSequence {
    @synchronized (self) {
        return _notificationSequence;
    }
}

- (void)updateAudioPolicyEpoch:(uint64_t)audioPolicyEpoch {
    @synchronized (self) {
        if (!_invalidated) {
            _audioPolicyEpoch = audioPolicyEpoch;
        }
    }
}

- (void)invalidate {
    __block id notificationToken = nil;
    __block uint64_t observerIdentifier = 0;
    @synchronized (self) {
        if (_invalidated) {
            return;
        }
        _invalidated = YES;
        _generation += 1;
        if (_generation == 0) {
            _generation = 1;
        }
        _handler = nil;
        notificationToken = _notificationToken;
        _notificationToken = nil;
        observerIdentifier = _observerIdentifier;
        _observerIdentifier = 0;
    }
    if (notificationToken != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:notificationToken];
    }
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
}

- (void)dealloc {
    [self invalidate];
}

@end

// All realtime counters and sign state must compile to native lock-free instructions on every
// supported 64-bit iOS device/simulator architecture. A toolchain/architecture that cannot make
// that guarantee must fail the build instead of silently introducing a callback-side lock.
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "64-bit realtime atomics must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit realtime atomics must be lock-free");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "boolean realtime atomics must be lock-free");
_Static_assert(sizeof(unsigned long) == 8, "unsigned long gate state must be 64-bit");
_Static_assert(
    sizeof(uintptr_t) <= sizeof(unsigned long),
    "gate publications must fit in atomic_ulong"
);

#define AS_REALTIME_GATE_CLOSED_BIT \
    (1UL << ((sizeof(unsigned long) * CHAR_BIT) - 1))
#define AS_REALTIME_GATE_COUNT_MASK (AS_REALTIME_GATE_CLOSED_BIT - 1UL)

typedef struct ASRealtimeGate {
    atomic_ulong state;
} ASRealtimeGate;

static _Thread_local ASRealtimeGate *ASCurrentRealtimeDeviceAdmissionGate = NULL;
static _Thread_local ASRealtimeGate *ASCurrentRealtimeAuthorizationAdmissionGate = NULL;

__attribute__((noreturn))
static void ASFailRealtimeGateInvariant(void) {
    __builtin_trap();
}

static inline void ASInitializeRealtimeGateOpen(ASRealtimeGate *gate) {
    atomic_init(&gate->state, 0);
}

static inline void ASInitializeRealtimeGateClosed(ASRealtimeGate *gate) {
    atomic_init(&gate->state, AS_REALTIME_GATE_CLOSED_BIT);
}

static inline BOOL ASRealtimeGateIsClosed(ASRealtimeGate *gate) {
    return (atomic_load_explicit(&gate->state, memory_order_acquire)
        & AS_REALTIME_GATE_CLOSED_BIT) != 0;
}

static inline BOOL ASRealtimeGateIsClosedAndDrained(ASRealtimeGate *gate) {
    return atomic_load_explicit(&gate->state, memory_order_acquire)
        == AS_REALTIME_GATE_CLOSED_BIT;
}

static inline BOOL ASBeginRealtimeGate(ASRealtimeGate *gate) {
    unsigned long observed = atomic_load_explicit(
        &gate->state,
        memory_order_acquire
    );
    for (;;) {
        if ((observed & AS_REALTIME_GATE_CLOSED_BIT) != 0) {
            return NO;
        }
        if ((observed & AS_REALTIME_GATE_COUNT_MASK)
            == AS_REALTIME_GATE_COUNT_MASK) {
            ASFailRealtimeGateInvariant();
        }

        unsigned long desired = observed + 1UL;
        if (atomic_compare_exchange_weak_explicit(
                &gate->state,
                &observed,
                desired,
                memory_order_acq_rel,
                memory_order_acquire)) {
            return YES;
        }
    }
}

static inline void ASEndRealtimeGate(ASRealtimeGate *gate) {
    unsigned long observed = atomic_load_explicit(
        &gate->state,
        memory_order_acquire
    );
    for (;;) {
        if ((observed & AS_REALTIME_GATE_COUNT_MASK) == 0) {
            ASFailRealtimeGateInvariant();
        }

        unsigned long desired = observed - 1UL;
        if (atomic_compare_exchange_weak_explicit(
                &gate->state,
                &observed,
                desired,
                memory_order_release,
                memory_order_relaxed)) {
            return;
        }
    }
}

static inline BOOL ASCloseRealtimeGate(ASRealtimeGate *gate) {
    unsigned long previous = atomic_fetch_or_explicit(
        &gate->state,
        AS_REALTIME_GATE_CLOSED_BIT,
        memory_order_acq_rel
    );
    return (previous & AS_REALTIME_GATE_CLOSED_BIT) == 0;
}

static inline void ASAssertRealtimeGateCanDrain(ASRealtimeGate *gate) {
    if (ASCurrentRealtimeDeviceAdmissionGate == gate
        || ASCurrentRealtimeAuthorizationAdmissionGate == gate) {
        ASFailRealtimeGateInvariant();
    }
}

static inline void ASDrainRealtimeGate(ASRealtimeGate *gate) {
    while ((atomic_load_explicit(&gate->state, memory_order_acquire)
            & AS_REALTIME_GATE_COUNT_MASK) != 0) {
        sched_yield();
    }
}

static inline void ASResetClosedRealtimeGate(ASRealtimeGate *gate) {
    unsigned long expected = AS_REALTIME_GATE_CLOSED_BIT;
    if (!atomic_compare_exchange_strong_explicit(
            &gate->state,
            &expected,
            0,
            memory_order_acq_rel,
            memory_order_acquire)) {
        ASFailRealtimeGateInvariant();
    }
}

static inline BOOL ASBeginDeviceRealtimeAdmission(ASRealtimeGate *gate) {
    if (ASCurrentRealtimeDeviceAdmissionGate != NULL) {
        ASFailRealtimeGateInvariant();
    }
    if (!ASBeginRealtimeGate(gate)) {
        return NO;
    }
    ASCurrentRealtimeDeviceAdmissionGate = gate;
    return YES;
}

static inline void ASEndDeviceRealtimeAdmission(ASRealtimeGate *gate) {
    if (ASCurrentRealtimeDeviceAdmissionGate != gate) {
        ASFailRealtimeGateInvariant();
    }
    ASEndRealtimeGate(gate);
    ASCurrentRealtimeDeviceAdmissionGate = NULL;
}

static inline BOOL ASBeginAuthorizationRealtimeAdmission(ASRealtimeGate *gate) {
    if (ASCurrentRealtimeAuthorizationAdmissionGate != NULL) {
        ASFailRealtimeGateInvariant();
    }
    if (!ASBeginRealtimeGate(gate)) {
        return NO;
    }
    ASCurrentRealtimeAuthorizationAdmissionGate = gate;
    return YES;
}

static inline void ASEndAuthorizationRealtimeAdmission(ASRealtimeGate *gate) {
    if (ASCurrentRealtimeAuthorizationAdmissionGate != gate) {
        ASFailRealtimeGateInvariant();
    }
    ASEndRealtimeGate(gate);
    ASCurrentRealtimeAuthorizationAdmissionGate = NULL;
}

/// `AVAudioSession` is process-global. Serializing activation/deactivation and assigning every
/// successful activation a monotonically increasing lease prevents a retiring peer from calling
/// `setActive:NO` after a newer peer has become the process's audio owner. AVAudioSession mutation
/// may synchronously enter a route observer while this lock is held; code holding the expected-
/// route lock must therefore never acquire this lock and must use the release/acquire snapshot.
static os_unfair_lock ASSessionOwnershipLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock ASSessionConfigurationLock = OS_UNFAIR_LOCK_INIT;
static uint64_t ASNextSessionOwnershipToken = 0;
static uint64_t ASCurrentSessionOwnershipToken = 0;
static atomic_uint_fast64_t ASCurrentSessionOwnershipTokenSnapshot =
    ATOMIC_VAR_INIT(0);

static BOOL ASBoundOwnershipTokenMatchesSnapshot(
    uint64_t boundOwnershipToken,
    uint64_t ownershipTokenSnapshot
) {
    return boundOwnershipToken != 0
        && boundOwnershipToken == ownershipTokenSnapshot;
}

typedef struct ASUnfairLockScope {
    os_unfair_lock *lock;
} ASUnfairLockScope;

static void ASReleaseUnfairLockScope(ASUnfairLockScope *scope) {
    if (scope->lock != NULL) {
        os_unfair_lock_unlock(scope->lock);
        scope->lock = NULL;
    }
}

typedef OSStatus (*ASAudioUnitStopFunction)(AudioUnit audioUnit);

static OSStatus ASStopAudioUnitIfRunning(
    AudioUnit audioUnit,
    BOOL *running,
    ASAudioUnitStopFunction stopFunction
) {
    if (audioUnit == NULL || running == NULL || !*running) {
        return noErr;
    }
    if (stopFunction == NULL) {
        *running = NO;
        return kAudio_ParamError;
    }
    OSStatus status = stopFunction(audioUnit);
    *running = NO;
    return status;
}

#if DEBUG
static NSUInteger ASDebugAudioUnitStopInvocationCount = 0;

static OSStatus ASDebugAudioUnitStop(AudioUnit audioUnit) {
    if (audioUnit == NULL) {
        return kAudio_ParamError;
    }
    ASDebugAudioUnitStopInvocationCount += 1;
    return noErr;
}
#endif

typedef NS_ENUM(NSUInteger, ASSystemAudioEvent) {
    ASSystemAudioEventInterruptionBegan,
    ASSystemAudioEventInterruptionEnded,
    ASSystemAudioEventRouteChanged,
    ASSystemAudioEventMediaServicesReset,
};

typedef NS_ENUM(NSUInteger, ASHostedCallRecoveryReadiness) {
    ASHostedCallRecoveryReadinessReady,
    ASHostedCallRecoveryReadinessAwaitingFailClose,
    ASHostedCallRecoveryReadinessCoalesced,
    ASHostedCallRecoveryReadinessRejected,
};

/// Inputs shared by the real AVAudioSession/RemoteIO configuration path and the deterministic
/// harness boundary. Recording this value proves which production choices were submitted; it is
/// deliberately not evidence that Simulator created a hardware AudioUnit.
typedef struct ASAudioPolicyConfiguration {
    AVAudioSessionCategoryOptions categoryOptions;
    AVAudioSessionRouteSharingPolicy routeSharingPolicy;
    BOOL inputBusEnabled;
    BOOL outputBusEnabled;
    AudioStreamBasicDescription outputStreamFormat;
} ASAudioPolicyConfiguration;

typedef NS_ENUM(NSUInteger, ASActiveChannelPreferenceFailure) {
    ASActiveChannelPreferenceFailureNone,
    ASActiveChannelPreferenceFailureSessionInactive,
    ASActiveChannelPreferenceFailureOutputUnavailable,
    ASActiveChannelPreferenceFailureOutputRequest,
    ASActiveChannelPreferenceFailureInputUnavailable,
    ASActiveChannelPreferenceFailureInputRequest,
};

typedef NS_ENUM(NSUInteger, ASOwnedSessionConfigurationFailure) {
    ASOwnedSessionConfigurationFailureNone,
    ASOwnedSessionConfigurationFailureActivation,
    ASOwnedSessionConfigurationFailureBuiltInMicrophoneUnavailable,
    ASOwnedSessionConfigurationFailurePreferredInputRequest,
    ASOwnedSessionConfigurationFailurePreferredInputDidNotConverge,
    ASOwnedSessionConfigurationFailureSessionInactive,
    ASOwnedSessionConfigurationFailureOutputUnavailable,
    ASOwnedSessionConfigurationFailureOutputRequest,
    ASOwnedSessionConfigurationFailureInputUnavailable,
    ASOwnedSessionConfigurationFailureInputRequest,
};

typedef NS_ENUM(NSUInteger, ASExpectedMicrophoneRouteChangeState) {
    ASExpectedMicrophoneRouteChangeStateNone,
    ASExpectedMicrophoneRouteChangeStatePending,
    ASExpectedMicrophoneRouteChangeStatePrepared,
    ASExpectedMicrophoneRouteChangeStateStarting,
    ASExpectedMicrophoneRouteChangeStateConsumed,
    ASExpectedMicrophoneRouteChangeStateRejected,
};

typedef NS_ENUM(NSUInteger, ASRouteTransactionDiagnosticPhase) {
    ASRouteTransactionDiagnosticPhaseArm,
    ASRouteTransactionDiagnosticPhasePrepare,
    ASRouteTransactionDiagnosticPhaseBeginStart,
    ASRouteTransactionDiagnosticPhaseNativeStart,
    ASRouteTransactionDiagnosticPhaseMarkStartCompleted,
    ASRouteTransactionDiagnosticPhaseCommit,
    ASRouteTransactionDiagnosticPhasePublish,
    ASRouteTransactionDiagnosticPhaseObservationRejection,
    ASRouteTransactionDiagnosticPhaseFreshReopen,
};

static BOOL ASQueuedRouteObservationMatchesTransactionIdentifier(
    uint64_t capturedTransactionIdentifier,
    uint64_t currentTransactionIdentifier
) {
    return capturedTransactionIdentifier != 0
        && capturedTransactionIdentifier == currentTransactionIdentifier;
}

static BOOL ASValidatedRouteNotificationSequenceIsCurrent(
    uint64_t validatedNotificationSequence,
    uint64_t currentNotificationSequence
) {
    return validatedNotificationSequence != 0
        && validatedNotificationSequence == currentNotificationSequence;
}

typedef struct ASExpectedRouteChangeEvidence {
    ASExpectedMicrophoneRouteChangeState state;
    AVAudioSessionRouteChangeReason reason;
    BOOL sequenceAdvanced;
    BOOL withinDeadline;
    BOOL configurationGenerationMatches;
    BOOL systemAudioGenerationMatches;
    BOOL fingerprintsArePresent;
    BOOL previousFingerprintWasObserved;
    BOOL policyIsExact;
    BOOL ownershipIsBound;
    BOOL ownershipMatches;
    BOOL sessionActive;
    BOOL recoveryRequired;
    BOOL explicitResumeRequired;
    BOOL currentRouteMatchesConvergedRoute;
    BOOL outputIsExact;
    BOOL channelsAreExact;
    BOOL targetInputIsExact;
    BOOL preferredInputIsExact;
    BOOL remoteIOStartSettlementProvenanceMatches;
} ASExpectedRouteChangeEvidence;

typedef NS_ENUM(NSUInteger, ASRemoteIOStartSettlementState) {
    ASRemoteIOStartSettlementStateRetired = 0,
    ASRemoteIOStartSettlementStateArmed,
    ASRemoteIOStartSettlementStateConsumedWhileStarting,
};

typedef struct ASRemoteIOStartSettlement {
    ASRemoteIOStartSettlementState state;
    uint64_t transactionIdentifier;
    uint64_t notificationSequenceBaseline;
    uint64_t deadlineNanoseconds;
} ASRemoteIOStartSettlement;

static ASRemoteIOStartSettlement ASMakeRemoteIOStartSettlement(
    uint64_t transactionIdentifier,
    uint64_t notificationSequenceBaseline,
    uint64_t startCompletedNanoseconds
) {
    ASRemoteIOStartSettlement settlement = {0};
    if (transactionIdentifier == 0 || startCompletedNanoseconds == 0) {
        return settlement;
    }
    settlement.state = ASRemoteIOStartSettlementStateArmed;
    settlement.transactionIdentifier = transactionIdentifier;
    settlement.notificationSequenceBaseline = notificationSequenceBaseline;
    settlement.deadlineNanoseconds =
        startCompletedNanoseconds > UINT64_MAX
                - ASRemoteIOStartSettlementLifetimeNanoseconds
        ? UINT64_MAX
        : startCompletedNanoseconds
            + ASRemoteIOStartSettlementLifetimeNanoseconds;
    return settlement;
}

static BOOL ASRemoteIOStartSettlementIsCurrent(
    ASRemoteIOStartSettlement settlement,
    uint64_t transactionIdentifier,
    uint64_t nowNanoseconds
) {
    BOOL stateIsLive =
        settlement.state == ASRemoteIOStartSettlementStateArmed
        || settlement.state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting;
    return stateIsLive
        && settlement.transactionIdentifier != 0
        && settlement.transactionIdentifier == transactionIdentifier
        && settlement.deadlineNanoseconds != 0
        && nowNanoseconds != 0
        && nowNanoseconds <= settlement.deadlineNanoseconds;
}

static BOOL ASRemoteIOStartSettlementAuthorizesObservation(
    ASRemoteIOStartSettlement settlement,
    uint64_t transactionIdentifier,
    uint64_t notificationSequence,
    uint64_t observedAtNanoseconds
) {
    return settlement.state == ASRemoteIOStartSettlementStateArmed
        && ASRemoteIOStartSettlementIsCurrent(
            settlement,
            transactionIdentifier,
            observedAtNanoseconds
        )
        && notificationSequence
            > settlement.notificationSequenceBaseline;
}

static void ASRetireRemoteIOStartSettlement(
    ASRemoteIOStartSettlement *settlement
) {
    if (settlement != NULL) {
        *settlement = (ASRemoteIOStartSettlement){0};
    }
}

static BOOL ASConsumeRemoteIOStartSettlementWhileStarting(
    ASRemoteIOStartSettlement *settlement,
    uint64_t transactionIdentifier
) {
    if (settlement == NULL || transactionIdentifier == 0) {
        return NO;
    }
    if (settlement->state == ASRemoteIOStartSettlementStateRetired) {
        // AudioOutputUnitStart may synchronously trigger the exact reason-8 before it returns and
        // before the return-boundary stamp exists. Preserve that consumption as a transaction-only
        // marker; markExpected... will add the immutable sequence/deadline without re-arming it.
        settlement->transactionIdentifier = transactionIdentifier;
    } else if (settlement->transactionIdentifier != transactionIdentifier) {
        return NO;
    }
    settlement->state =
        ASRemoteIOStartSettlementStateConsumedWhileStarting;
    return YES;
}

static BOOL ASFinalizeRemoteIOStartSettlementForCommit(
    ASRemoteIOStartSettlement *settlement,
    uint64_t transactionIdentifier,
    uint64_t nowNanoseconds
) {
    if (settlement == NULL
        || !ASRemoteIOStartSettlementIsCurrent(
            *settlement,
            transactionIdentifier,
            nowNanoseconds
        )) {
        return NO;
    }
    if (settlement->state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting) {
        ASRetireRemoteIOStartSettlement(settlement);
    }
    return YES;
}

static BOOL ASCommitExpectedMicrophoneRouteChangeStartState(
    ASExpectedMicrophoneRouteChangeState *routeState,
    ASRemoteIOStartSettlement *settlement,
    uint64_t transactionIdentifier,
    uint64_t nowNanoseconds
) {
    if (routeState == NULL
        || *routeState != ASExpectedMicrophoneRouteChangeStateStarting
        || !ASFinalizeRemoteIOStartSettlementForCommit(
            settlement,
            transactionIdentifier,
            nowNanoseconds
        )) {
        return NO;
    }
    *routeState = ASExpectedMicrophoneRouteChangeStateConsumed;
    return YES;
}

typedef NS_ENUM(NSUInteger, ASExpectedRouteObservationHandling) {
    ASExpectedRouteObservationHandlingGeneric = 0,
    ASExpectedRouteObservationHandlingConsumed = 1,
    ASExpectedRouteObservationHandlingLiveRejectionOwnedByWaiter = 2,
    ASExpectedRouteObservationHandlingExpectedCategory = 3,
};

static ASIOSExpectedRouteChangeDisposition
ASClassifyExpectedRouteChangeEvidence(
    ASExpectedRouteChangeEvidence evidence
) {
    if (evidence.reason == AVAudioSessionRouteChangeReasonCategoryChange) {
        return ASIOSExpectedRouteChangeDispositionUnrelated;
    }
    BOOL exactCurrentEvidence = evidence.reason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange
        && evidence.sequenceAdvanced
        && evidence.withinDeadline
        && evidence.configurationGenerationMatches
        && evidence.systemAudioGenerationMatches
        && evidence.fingerprintsArePresent
        && evidence.policyIsExact;
    BOOL chainedEvidence = exactCurrentEvidence
        && evidence.previousFingerprintWasObserved;
    if (evidence.state == ASExpectedMicrophoneRouteChangeStatePending) {
        BOOL ownershipIsAdmissible = !evidence.ownershipIsBound
            || (evidence.ownershipMatches && evidence.sessionActive);
        return chainedEvidence
                && evidence.outputIsExact
                && ownershipIsAdmissible
            ? ASIOSExpectedRouteChangeDispositionConsume
            : ASIOSExpectedRouteChangeDispositionRejectTransaction;
    }
    if (evidence.state == ASExpectedMicrophoneRouteChangeStatePrepared
        || evidence.state == ASExpectedMicrophoneRouteChangeStateStarting) {
        BOOL exactBoundTransaction = exactCurrentEvidence
            && evidence.ownershipIsBound
            && evidence.ownershipMatches
            && evidence.sessionActive
            && !evidence.recoveryRequired
            && !evidence.explicitResumeRequired
            && evidence.currentRouteMatchesConvergedRoute
            && evidence.outputIsExact
            && evidence.channelsAreExact
            && evidence.targetInputIsExact
            && evidence.preferredInputIsExact;
        return exactBoundTransaction
            ? ASIOSExpectedRouteChangeDispositionConsume
            : ASIOSExpectedRouteChangeDispositionRejectTransaction;
    }
    if (evidence.state == ASExpectedMicrophoneRouteChangeStateConsumed) {
        BOOL exactConsumedRoute = exactCurrentEvidence
            && evidence.ownershipIsBound
            && evidence.ownershipMatches
            && evidence.sessionActive
            && !evidence.recoveryRequired
            && !evidence.explicitResumeRequired
            && evidence.currentRouteMatchesConvergedRoute
            && evidence.outputIsExact
            && evidence.channelsAreExact
            && evidence.targetInputIsExact
            && evidence.preferredInputIsExact;
        // Ordinary post-publication duplicates must still chain to the observed cursor. The sole
        // exception is one otherwise-exact reason-8 ingress carrying the explicit, bounded claim
        // stamped immediately after this transaction's AudioOutputUnitStart returned. This admits
        // a coalesced start notification even when its previous route was not separately observed,
        // without allowing a later transaction or inexact route to borrow startup provenance.
        BOOL exactDuplicate = exactConsumedRoute
            && evidence.previousFingerprintWasObserved;
        BOOL exactSettlingStartObservation = exactConsumedRoute
            && evidence.remoteIOStartSettlementProvenanceMatches;
        return exactDuplicate || exactSettlingStartObservation
            ? ASIOSExpectedRouteChangeDispositionConsume
            : ASIOSExpectedRouteChangeDispositionUnrelated;
    }
    return ASIOSExpectedRouteChangeDispositionUnrelated;
}

static BOOL ASShouldSuppressSupersededRouteConfigurationObservation(
    AVAudioSessionRouteChangeReason reason,
    uint64_t notificationSequence,
    uint64_t capturedTransactionIdentifier,
    ASExpectedMicrophoneRouteChangeState currentState,
    uint64_t currentTransactionIdentifier,
    uint64_t currentObserverSequenceBaseline
) {
    // A route-configuration notification that entered before a newer
    // transaction armed is already represented by that transaction's initial
    // route fingerprint. Forwarding it later to the generic handler would let
    // stale queue latency tear down the newer session. Never extend this
    // suppression to physical device loss or other route reasons.
    BOOL currentTransactionIsLive =
        currentState == ASExpectedMicrophoneRouteChangeStatePending
        || currentState == ASExpectedMicrophoneRouteChangeStatePrepared
        || currentState == ASExpectedMicrophoneRouteChangeStateStarting
        || currentState == ASExpectedMicrophoneRouteChangeStateConsumed;
    return reason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange
        && notificationSequence != 0
        && currentTransactionIsLive
        && currentTransactionIdentifier != 0
        && currentTransactionIdentifier
            != capturedTransactionIdentifier
        && notificationSequence <= currentObserverSequenceBaseline;
}

static BOOL ASShouldSuppressRetiredSystemAudioGenerationObservation(
    AVAudioSessionRouteChangeReason reason,
    uint64_t capturedSystemAudioGeneration,
    uint64_t currentSystemAudioGeneration
) {
    // A reason-8 observation captured before a teardown/rebuild belongs to
    // the retired audio epoch. Once that epoch changes it cannot describe the
    // live session, even when the newer policy is output-only and therefore
    // has no ordinary route transaction identifier. Physical device loss is
    // intentionally excluded and must always reach explicit-resume policy.
    return reason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange
        && capturedSystemAudioGeneration
            != currentSystemAudioGeneration;
}

static BOOL ASRouteEvidenceOwnsDeviceGateClosure(
    BOOL routeClosureRecorded,
    NSUInteger notificationInFlightCount
) {
    // The recorded-closure bit is set synchronously at ingress under the same
    // lock as the in-flight count, so it is the authoritative ownership bit.
    // Every tracked route observation, including CategoryChange, records this
    // bit before asynchronous evidence processing can race publication.
    (void)notificationInFlightCount;
    return routeClosureRecorded;
}

static BOOL ASMustCloseRealtimeRouteGatesForObservation(
    AVAudioSessionRouteChangeReason reason,
    BOOL playing,
    BOOL trackedTransaction
) {
    // Category changes can mutate the exact category/options policy while a
    // microphone authorization is being published, but only a tracked route
    // transaction owns the exact fresh-resolution path that can reopen these
    // gates. Output-only/hosted category observations are still validated by
    // the generic handler and must not create an unowned permanent closure.
    if (reason == AVAudioSessionRouteChangeReasonCategoryChange) {
        return playing && trackedTransaction;
    }
    return playing;
}

static BOOL ASShouldScheduleRouteGateClosureResolution(
    BOOL routeClosureRecorded,
    NSUInteger notificationInFlightCount,
    ASExpectedMicrophoneRouteChangeState state,
    BOOL playing
) {
    // Resolve every recorded closure after the ordered evidence queue drains.
    // The device queue will take a fresh session snapshot and either reopen
    // exact gates or roll back. The last queued notification's snapshot is
    // deliberately not an input to this decision.
    return routeClosureRecorded
        && notificationInFlightCount == 0
        && state == ASExpectedMicrophoneRouteChangeStateConsumed
        && playing;
}

static BOOL ASFinalMicrophoneRouteValidationIsCurrent(
    uint64_t validatedTransactionIdentifier,
    uint64_t currentTransactionIdentifier,
    uint64_t validatedTransactionRevision,
    uint64_t currentTransactionRevision,
    uint64_t validatedNotificationSequence,
    uint64_t currentNotificationSequence,
    NSUInteger notificationInFlightCount,
    ASExpectedMicrophoneRouteChangeState state
) {
    // Both category and route notifications increment the ingress sequence before asynchronous
    // evidence processing. A delayed callback admitted after the fresh session sample therefore
    // blocks final microphone publication even if its evidence queue has not run yet.
    return validatedTransactionIdentifier != 0
        && validatedTransactionIdentifier == currentTransactionIdentifier
        && validatedTransactionRevision != 0
        && validatedTransactionRevision == currentTransactionRevision
        && validatedNotificationSequence == currentNotificationSequence
        && notificationInFlightCount == 0
        && state == ASExpectedMicrophoneRouteChangeStateConsumed;
}

@interface ASRouteTransactionFailureSnapshot : NSObject
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *state;
@property(nonatomic) uint64_t transactionIdentifier;
@property(nonatomic) uint64_t expectedTransactionIdentifier;
@property(nonatomic) uint64_t notificationSequence;
@property(nonatomic) uint64_t observerSequenceBaseline;
@property(nonatomic) uint64_t requiredNotificationSequence;
@property(nonatomic) NSUInteger notificationInFlightCount;
@property(nonatomic) uint64_t boundConfigurationGeneration;
@property(nonatomic) uint64_t currentConfigurationGeneration;
@property(nonatomic) uint64_t boundSystemAudioGeneration;
@property(nonatomic) uint64_t currentSystemAudioGeneration;
@property(nonatomic) uint64_t boundOwnershipToken;
@property(nonatomic) uint64_t currentOwnershipToken;
@property(nonatomic) BOOL sessionActive;
@property(nonatomic) BOOL recoveryRequired;
@property(nonatomic) BOOL explicitResumeRequired;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL routeClosureRecorded;
@property(nonatomic) BOOL inputRequired;
@property(nonatomic) BOOL preferredInputRequired;
@property(nonatomic) BOOL playoutGateClosedAndDrained;
@property(nonatomic) BOOL microphoneGateClosedAndDrained;
@property(nonatomic, copy) NSString *boundCursorFingerprint;
@property(nonatomic, copy) NSString *boundPreparedRouteFingerprint;
@property(nonatomic, copy) NSString *boundOutputFingerprint;
@property(nonatomic, copy) NSString *boundTargetInputIdentifier;
@property(nonatomic, copy) NSString *currentRouteFingerprint;
@property(nonatomic, copy) NSString *currentOutputFingerprint;
@property(nonatomic, copy) NSString *currentInputType;
@property(nonatomic, copy) NSString *currentInputIdentifier;
@property(nonatomic, copy) NSString *preferredInputType;
@property(nonatomic, copy) NSString *preferredInputIdentifier;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) AVAudioSessionCategoryOptions categoryOptions;
@property(nonatomic) AVAudioSessionRouteSharingPolicy sharingPolicy;
@property(nonatomic) NSUInteger inputCount;
@property(nonatomic) NSUInteger outputCount;
@property(nonatomic) NSInteger inputChannels;
@property(nonatomic) NSInteger outputChannels;
@property(nonatomic, copy) NSArray<NSString *> *failedPredicates;
@end

@implementation ASRouteTransactionFailureSnapshot
@end

@interface ASExpectedRouteObservationSnapshot : NSObject
@property(nonatomic, copy) NSString *currentRouteFingerprint;
@property(nonatomic, copy) NSString *currentOutputFingerprint;
@property(nonatomic, copy) NSString *currentInputType;
@property(nonatomic, copy) NSString *currentInputIdentifier;
@property(nonatomic, copy) NSString *preferredInputType;
@property(nonatomic, copy) NSString *preferredInputIdentifier;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) AVAudioSessionCategoryOptions categoryOptions;
@property(nonatomic) AVAudioSessionRouteSharingPolicy sharingPolicy;
@property(nonatomic) NSUInteger inputCount;
@property(nonatomic) NSUInteger outputCount;
@property(nonatomic) NSInteger inputChannels;
@property(nonatomic) NSInteger outputChannels;
@property(nonatomic) uint64_t activeConfigurationGeneration;
@property(nonatomic) uint64_t currentOwnershipToken;
@property(nonatomic) uint64_t systemAudioGeneration;
@property(nonatomic) BOOL sessionActive;
@property(nonatomic) BOOL recoveryRequired;
@property(nonatomic) BOOL explicitResumeRequired;
@property(nonatomic) BOOL expectedInputRequired;
@property(nonatomic) uint64_t expectedObserverSequenceBaseline;
@property(nonatomic) uint64_t expectedDeadlineNanoseconds;
@property(nonatomic) uint64_t observedAt;
@property(nonatomic, copy) NSString *previousRouteFingerprint;
@end

@implementation ASExpectedRouteObservationSnapshot
@end

@protocol ASAudioSessionChannelPreferenceConfiguring <NSObject>
@property(nonatomic, readonly) NSInteger inputNumberOfChannels;
@property(nonatomic, readonly) NSInteger outputNumberOfChannels;
@property(nonatomic, readonly) NSInteger maximumInputNumberOfChannels;
@property(nonatomic, readonly) NSInteger maximumOutputNumberOfChannels;
- (BOOL)setPreferredInputNumberOfChannels:(NSInteger)count
                                    error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setPreferredOutputNumberOfChannels:(NSInteger)count
                                     error:(NSError *_Nullable *_Nullable)error;
@end

/// Channel-count preferences describe the active hardware route, not the stale route that happened
/// to exist before this app activated `playAndRecord`. In particular, an inactive A2DP route is
/// output-only and truthfully reports zero maximum input channels. Apple requires both channel
/// preference setters to run only after category/mode selection and session activation.
static ASActiveChannelPreferenceFailure ASApplyActiveChannelPreferences(
    id<ASAudioSessionChannelPreferenceConfiguring> session,
    BOOL sessionActive,
    BOOL microphoneEnabled,
    NSError **error
) {
    if (!sessionActive) {
        return ASActiveChannelPreferenceFailureSessionInactive;
    }
    if (session.maximumOutputNumberOfChannels < ASOutputChannelCount) {
        return ASActiveChannelPreferenceFailureOutputUnavailable;
    }
    if (microphoneEnabled
        && session.maximumInputNumberOfChannels < ASInputChannelCount) {
        return ASActiveChannelPreferenceFailureInputUnavailable;
    }
    if (session.outputNumberOfChannels != ASOutputChannelCount) {
        if (![session
                setPreferredOutputNumberOfChannels:ASOutputChannelCount
                                             error:error]) {
            return ASActiveChannelPreferenceFailureOutputRequest;
        }
    }
    if (!microphoneEnabled) {
        return ASActiveChannelPreferenceFailureNone;
    }
    if (session.maximumInputNumberOfChannels < ASInputChannelCount) {
        return ASActiveChannelPreferenceFailureInputUnavailable;
    }
    if (session.inputNumberOfChannels != ASInputChannelCount) {
        if (![session
                setPreferredInputNumberOfChannels:ASInputChannelCount
                                            error:error]) {
            return ASActiveChannelPreferenceFailureInputRequest;
        }
    }
    return ASActiveChannelPreferenceFailureNone;
}

static ASOwnedSessionConfigurationFailure ASOwnedSessionFailureForChannels(
    ASActiveChannelPreferenceFailure failure
) {
    switch (failure) {
        case ASActiveChannelPreferenceFailureNone:
            return ASOwnedSessionConfigurationFailureNone;
        case ASActiveChannelPreferenceFailureSessionInactive:
            return ASOwnedSessionConfigurationFailureSessionInactive;
        case ASActiveChannelPreferenceFailureOutputUnavailable:
            return ASOwnedSessionConfigurationFailureOutputUnavailable;
        case ASActiveChannelPreferenceFailureOutputRequest:
            return ASOwnedSessionConfigurationFailureOutputRequest;
        case ASActiveChannelPreferenceFailureInputUnavailable:
            return ASOwnedSessionConfigurationFailureInputUnavailable;
        case ASActiveChannelPreferenceFailureInputRequest:
            return ASOwnedSessionConfigurationFailureInputRequest;
    }
    return ASOwnedSessionConfigurationFailureSessionInactive;
}

static AVAudioSessionCategoryOptions ASIPhoneMicrophoneCategoryOptions(void) {
    return AVAudioSessionCategoryOptionDefaultToSpeaker
        | AVAudioSessionCategoryOptionAllowBluetoothA2DP;
}

/// A category notification can be delivered after the exact native transaction that authored it
/// has advanced or retired. Validate it against the immutable policy captured at ingress instead
/// of recomputing policy from later microphone ownership. This is observational only: it neither
/// proves route convergence nor opens a realtime gate.
static BOOL ASExpectedCategoryObservationMatchesCapturedPolicy(
    AVAudioSessionRouteChangeReason reason,
    BOOL trackedTransaction,
    ASExpectedMicrophoneRouteChangeState entryState,
    uint64_t transactionIdentifier,
    uint64_t entryConfigurationGeneration,
    uint64_t activeConfigurationGeneration,
    uint64_t entrySystemAudioGeneration,
    uint64_t observedSystemAudioGeneration,
    uint64_t notificationSequence,
    uint64_t observerSequenceBaseline,
    uint64_t observedAtNanoseconds,
    uint64_t deadlineNanoseconds,
    BOOL inputRequired,
    NSString *category,
    NSString *mode,
    AVAudioSessionCategoryOptions options,
    AVAudioSessionRouteSharingPolicy sharingPolicy
) {
    BOOL entryStateWasLive =
        entryState == ASExpectedMicrophoneRouteChangeStatePending
        || entryState == ASExpectedMicrophoneRouteChangeStatePrepared
        || entryState == ASExpectedMicrophoneRouteChangeStateStarting
        || entryState == ASExpectedMicrophoneRouteChangeStateConsumed;
    AVAudioSessionCategory expectedCategory = inputRequired
        ? AVAudioSessionCategoryPlayAndRecord
        : AVAudioSessionCategoryPlayback;
    AVAudioSessionCategoryOptions expectedOptions = inputRequired
        ? ASIPhoneMicrophoneCategoryOptions()
        : 0;
    return reason == AVAudioSessionRouteChangeReasonCategoryChange
        && trackedTransaction
        && entryStateWasLive
        && transactionIdentifier != 0
        && entryConfigurationGeneration != 0
        && entryConfigurationGeneration == activeConfigurationGeneration
        && entrySystemAudioGeneration != 0
        && entrySystemAudioGeneration == observedSystemAudioGeneration
        && notificationSequence > observerSequenceBaseline
        && observedAtNanoseconds != 0
        && deadlineNanoseconds != 0
        && observedAtNanoseconds <= deadlineNanoseconds
        && [category isEqualToString:expectedCategory]
        && [mode isEqualToString:AVAudioSessionModeDefault]
        && options == expectedOptions
        && sharingPolicy == AVAudioSessionRouteSharingPolicyDefault;
}

static ASAudioPolicyConfiguration ASMakeAudioPolicyConfiguration(
    BOOL hostedCallMode,
    BOOL microphoneEnabled,
    AudioStreamBasicDescription outputStreamFormat
) {
    return (ASAudioPolicyConfiguration) {
        .categoryOptions = hostedCallMode
            ? AVAudioSessionCategoryOptionMixWithOthers
            : (microphoneEnabled
                ? ASIPhoneMicrophoneCategoryOptions()
                : 0),
        .routeSharingPolicy = AVAudioSessionRouteSharingPolicyDefault,
        .inputBusEnabled = microphoneEnabled,
        .outputBusEnabled = YES,
        .outputStreamFormat = outputStreamFormat,
    };
}

static AVAudioSessionCategory ASCategoryForAudioPolicyConfiguration(
    ASAudioPolicyConfiguration configuration
) {
    return configuration.inputBusEnabled
        ? AVAudioSessionCategoryPlayAndRecord
        : AVAudioSessionCategoryPlayback;
}

/// Failure-only route evidence. Port types identify receiver/speaker/Bluetooth policy without
/// exposing user-assigned device names.
static NSString *ASAudioSessionPortTypesDescription(
    NSArray<AVAudioSessionPortDescription *> *ports
) {
    if (ports.count == 0) {
        return @"none";
    }
    NSMutableArray<NSString *> *types =
        [NSMutableArray arrayWithCapacity:ports.count];
    for (AVAudioSessionPortDescription *port in ports) {
        [types addObject:port.portType ?: @"unknown"];
    }
    return [types componentsJoinedByString:@","];
}

static NSString *ASAudioSessionPortsFingerprint(
    NSArray<AVAudioSessionPortDescription *> *ports
) {
    NSMutableString *fingerprint = [NSMutableString string];
    [fingerprint appendFormat:@"%lu|", (unsigned long)ports.count];
    for (AVAudioSessionPortDescription *port in ports) {
        NSString *type = port.portType ?: @"";
        NSString *identifier = port.UID ?: @"";
        [fingerprint appendFormat:
            @"%lu:%@%lu:%@|",
            (unsigned long)type.length,
            type,
            (unsigned long)identifier.length,
            identifier];
    }
    return fingerprint;
}

static NSString *ASAudioSessionRouteFingerprint(
    AVAudioSessionRouteDescription *route
) {
    return [NSString stringWithFormat:
        @"inputs{%@}outputs{%@}",
        ASAudioSessionPortsFingerprint(route.inputs),
        ASAudioSessionPortsFingerprint(route.outputs)];
}

static NSString *ASRedactedStableFingerprint(NSString *value) {
    if (value == nil) {
        return @"none";
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return @"invalid";
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        CC_LONG chunk = (CC_LONG)MIN(
            remaining,
            (NSUInteger)UINT32_MAX
        );
        CC_SHA256_Update(&context, bytes, chunk);
        bytes += chunk;
        remaining -= chunk;
    }
    CC_SHA256_Final(digest, &context);

    // A 128-bit prefix is compact enough for failure messages while retaining
    // deterministic cross-run correlation. Raw port UIDs never leave this
    // translation unit through route-transaction diagnostics.
    NSMutableString *result = [NSMutableString stringWithString:@"sha256/128:"];
    for (NSUInteger index = 0; index < 16; index += 1) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static NSString *ASExpectedMicrophoneRouteChangeStateDescription(
    ASExpectedMicrophoneRouteChangeState state
) {
    switch (state) {
        case ASExpectedMicrophoneRouteChangeStateNone:
            return @"none";
        case ASExpectedMicrophoneRouteChangeStatePending:
            return @"pending";
        case ASExpectedMicrophoneRouteChangeStatePrepared:
            return @"prepared";
        case ASExpectedMicrophoneRouteChangeStateStarting:
            return @"starting";
        case ASExpectedMicrophoneRouteChangeStateConsumed:
            return @"consumed";
        case ASExpectedMicrophoneRouteChangeStateRejected:
            return @"rejected";
    }
    return @"unknown";
}

static NSString *ASImmutableRouteObservationRejectionDescription(
    ASExpectedRouteObservationSnapshot *snapshot,
    AVAudioSessionRouteChangeReason reason,
    uint64_t notificationSequence,
    uint64_t transactionIdentifier,
    ASExpectedMicrophoneRouteChangeState entryState,
    uint64_t boundConfigurationGeneration,
    uint64_t boundSystemAudioGeneration,
    uint64_t boundOwnershipToken
) {
    // This record is built from the immutable ingress snapshot, before a later route or teardown
    // can replace the evidence that actually rejected the transaction. Port identities are hashed.
    return [NSString stringWithFormat:
        @"routeTxn{phase=observation-rejection ingress=immutable state=%@ txn=%llu "
         "reason=%lu notification=%llu observedAt=%llu "
         "generation={configuration=%llu/%llu system=%llu/%llu} "
         "ownership={bound=%llu current=%llu} "
         "lifecycle={active=%d recovery=%d explicitResume=%d} "
         "route={previous=%@ current=%@ output=%@} "
         "policy={category=%@ mode=%@ options=%lu sharing=%lu} "
         "ports={inputCount=%lu outputCount=%lu inputChannels=%ld outputChannels=%ld "
         "inputType=%@ inputUID=%@ preferredType=%@ preferredUID=%@}}",
        ASExpectedMicrophoneRouteChangeStateDescription(entryState),
        (unsigned long long)transactionIdentifier,
        (unsigned long)reason,
        (unsigned long long)notificationSequence,
        (unsigned long long)snapshot.observedAt,
        (unsigned long long)boundConfigurationGeneration,
        (unsigned long long)snapshot.activeConfigurationGeneration,
        (unsigned long long)boundSystemAudioGeneration,
        (unsigned long long)snapshot.systemAudioGeneration,
        (unsigned long long)boundOwnershipToken,
        (unsigned long long)snapshot.currentOwnershipToken,
        snapshot.sessionActive,
        snapshot.recoveryRequired,
        snapshot.explicitResumeRequired,
        ASRedactedStableFingerprint(snapshot.previousRouteFingerprint),
        ASRedactedStableFingerprint(snapshot.currentRouteFingerprint),
        ASRedactedStableFingerprint(snapshot.currentOutputFingerprint),
        snapshot.category ?: @"none",
        snapshot.mode ?: @"none",
        (unsigned long)snapshot.categoryOptions,
        (unsigned long)snapshot.sharingPolicy,
        (unsigned long)snapshot.inputCount,
        (unsigned long)snapshot.outputCount,
        (long)snapshot.inputChannels,
        (long)snapshot.outputChannels,
        snapshot.currentInputType ?: @"none",
        ASRedactedStableFingerprint(snapshot.currentInputIdentifier),
        snapshot.preferredInputType ?: @"none",
        ASRedactedStableFingerprint(snapshot.preferredInputIdentifier)];
}

static NSString *ASRouteTransactionDiagnosticPhaseDescription(
    ASRouteTransactionDiagnosticPhase phase
) {
    switch (phase) {
        case ASRouteTransactionDiagnosticPhaseArm:
            return @"arm";
        case ASRouteTransactionDiagnosticPhasePrepare:
            return @"prepare";
        case ASRouteTransactionDiagnosticPhaseBeginStart:
            return @"begin-start";
        case ASRouteTransactionDiagnosticPhaseNativeStart:
            return @"native-start";
        case ASRouteTransactionDiagnosticPhaseMarkStartCompleted:
            return @"mark-start-completed";
        case ASRouteTransactionDiagnosticPhaseCommit:
            return @"commit";
        case ASRouteTransactionDiagnosticPhasePublish:
            return @"publish";
        case ASRouteTransactionDiagnosticPhaseObservationRejection:
            return @"observation-rejection";
        case ASRouteTransactionDiagnosticPhaseFreshReopen:
            return @"fresh-reopen";
    }
    return @"unknown";
}

static NSString *ASRouteTransactionFailureSnapshotDescription(
    ASRouteTransactionFailureSnapshot *snapshot
) {
    NSString *failed = snapshot.failedPredicates.count == 0
        ? @"none"
        : [snapshot.failedPredicates componentsJoinedByString:@","];
    return [NSString stringWithFormat:
        @"routeTxn{phase=%@ state=%@ txn=%llu expectedTxn=%llu "
         "notification={current=%llu baseline=%llu required=%llu inFlight=%lu} "
         "generation={configuration=%llu/%llu system=%llu/%llu} "
         "ownership={bound=%llu current=%llu} "
         "flags={active=%@ recovery=%@ explicitResume=%@ playing=%@ closure=%@ "
         "inputRequired=%@ preferredRequired=%@ playoutGateDrained=%@ micGateDrained=%@} "
         "failed=[%@] "
         "bound={cursor=%@ preparedRoute=%@ output=%@ targetInputUID=%@} "
         "current={route=%@ output=%@ inputType=%@ inputUID=%@ "
         "preferredInputType=%@ preferredInputUID=%@ inputs=%lu outputs=%lu "
         "inputChannels=%ld outputChannels=%ld category=%@ mode=%@ options=%lu sharing=%ld}}",
        snapshot.phase ?: @"unknown",
        snapshot.state ?: @"unknown",
        (unsigned long long)snapshot.transactionIdentifier,
        (unsigned long long)snapshot.expectedTransactionIdentifier,
        (unsigned long long)snapshot.notificationSequence,
        (unsigned long long)snapshot.observerSequenceBaseline,
        (unsigned long long)snapshot.requiredNotificationSequence,
        (unsigned long)snapshot.notificationInFlightCount,
        (unsigned long long)snapshot.boundConfigurationGeneration,
        (unsigned long long)snapshot.currentConfigurationGeneration,
        (unsigned long long)snapshot.boundSystemAudioGeneration,
        (unsigned long long)snapshot.currentSystemAudioGeneration,
        (unsigned long long)snapshot.boundOwnershipToken,
        (unsigned long long)snapshot.currentOwnershipToken,
        snapshot.sessionActive ? @"yes" : @"no",
        snapshot.recoveryRequired ? @"yes" : @"no",
        snapshot.explicitResumeRequired ? @"yes" : @"no",
        snapshot.playing ? @"yes" : @"no",
        snapshot.routeClosureRecorded ? @"yes" : @"no",
        snapshot.inputRequired ? @"yes" : @"no",
        snapshot.preferredInputRequired ? @"yes" : @"no",
        snapshot.playoutGateClosedAndDrained ? @"yes" : @"no",
        snapshot.microphoneGateClosedAndDrained ? @"yes" : @"no",
        failed,
        ASRedactedStableFingerprint(snapshot.boundCursorFingerprint),
        ASRedactedStableFingerprint(snapshot.boundPreparedRouteFingerprint),
        ASRedactedStableFingerprint(snapshot.boundOutputFingerprint),
        ASRedactedStableFingerprint(snapshot.boundTargetInputIdentifier),
        ASRedactedStableFingerprint(snapshot.currentRouteFingerprint),
        ASRedactedStableFingerprint(snapshot.currentOutputFingerprint),
        snapshot.currentInputType ?: @"none",
        ASRedactedStableFingerprint(snapshot.currentInputIdentifier),
        snapshot.preferredInputType ?: @"none",
        ASRedactedStableFingerprint(snapshot.preferredInputIdentifier),
        (unsigned long)snapshot.inputCount,
        (unsigned long)snapshot.outputCount,
        (long)snapshot.inputChannels,
        (long)snapshot.outputChannels,
        snapshot.category ?: @"none",
        snapshot.mode ?: @"none",
        (unsigned long)snapshot.categoryOptions,
        (long)snapshot.sharingPolicy];
}

static BOOL ASAudioSessionPortMatches(
    AVAudioSessionPortDescription *port,
    AVAudioSessionPort type,
    NSString *identifier
) {
    return port != nil
        && identifier.length > 0
        && [port.portType isEqualToString:type]
        && [port.UID isEqualToString:identifier];
}

static BOOL ASAudioSessionPortsContainBuiltInMicrophone(
    NSArray<AVAudioSessionPortDescription *> *ports
) {
    for (AVAudioSessionPortDescription *port in ports) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ASAudioSessionUsesBuiltInMicrophone(AVAudioSession *session) {
    return ASAudioSessionPortsContainBuiltInMicrophone(
        session.currentRoute.inputs
    );
}

static uint64_t ASMonotonicNanoseconds(void) {
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS
        || timebase.denom == 0) {
        return 0;
    }
    __uint128_t nanoseconds = (__uint128_t)mach_absolute_time()
        * timebase.numer / timebase.denom;
    return nanoseconds > UINT64_MAX
        ? UINT64_MAX
        : (uint64_t)nanoseconds;
}

static NSString *ASAudioSessionDiagnosticDescription(
    AVAudioSession *session
) {
    AVAudioSessionRouteDescription *route = session.currentRoute;
    return [NSString stringWithFormat:
        @"audioSession{category=%@, mode=%@, options=%lu, routeSharing=%ld, "
         "rate=%.1f, preferredRate=%.1f, duration=%.6f, preferredDuration=%.6f, "
         "inputAvailable=%@, input=%ld, preferredInput=%ld, maxInput=%ld, "
         "output=%ld, preferredOutput=%ld, maxOutput=%ld, inputs=%@, outputs=%@}",
        session.category,
        session.mode,
        (unsigned long)session.categoryOptions,
        (long)session.routeSharingPolicy,
        session.sampleRate,
        session.preferredSampleRate,
        session.IOBufferDuration,
        session.preferredIOBufferDuration,
        session.isInputAvailable ? @"yes" : @"no",
        (long)session.inputNumberOfChannels,
        (long)session.preferredInputNumberOfChannels,
        (long)session.maximumInputNumberOfChannels,
        (long)session.outputNumberOfChannels,
        (long)session.preferredOutputNumberOfChannels,
        (long)session.maximumOutputNumberOfChannels,
        ASAudioSessionPortTypesDescription(route.inputs),
        ASAudioSessionPortTypesDescription(route.outputs)];
}

static BOOL ASAudioStreamBasicDescriptionsEqual(
    AudioStreamBasicDescription lhs,
    AudioStreamBasicDescription rhs
) {
    return lhs.mSampleRate == rhs.mSampleRate
        && lhs.mFormatID == rhs.mFormatID
        && lhs.mFormatFlags == rhs.mFormatFlags
        && lhs.mBytesPerPacket == rhs.mBytesPerPacket
        && lhs.mFramesPerPacket == rhs.mFramesPerPacket
        && lhs.mBytesPerFrame == rhs.mBytesPerFrame
        && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
        && lhs.mBitsPerChannel == rhs.mBitsPerChannel
        && lhs.mReserved == rhs.mReserved;
}

typedef struct ASRealtimeDiagnostics {
    uint32_t hostTimebaseNumerator;
    uint32_t hostTimebaseDenominator;
    // Single RemoteIO writer sequence: odd while callback evidence is changing, even when a
    // reader may take a coherent snapshot. This prevents impossible max/count combinations from
    // being manufactured by independent lock-free atomic reads.
    atomic_uint_fast64_t publicationSequence;
    atomic_uint_fast64_t callbackCount;
    atomic_uint_fast64_t frameCount;
    atomic_uint_fast64_t failureCount;
    atomic_uint_fast64_t pcmSampleCount;
    atomic_uint_fast64_t pcmNonzeroSampleCount;
    atomic_uint_fast64_t pcmAbsoluteSampleSum;
    atomic_uint_fast64_t pcmLeftAbsoluteSampleSum;
    atomic_uint_fast64_t pcmRightAbsoluteSampleSum;
    atomic_uint_fast64_t pcmStereoDifferenceAbsoluteSampleSum;
    atomic_uint_fast64_t pcmClippedSampleCount;
    atomic_uint_fast64_t explicitSilenceCallbackCount;
    atomic_uint_fast64_t callbackGapViolationCount;
    atomic_uint_fast64_t maximumCallbackGapNanoseconds;
    atomic_uint_fast64_t lastSuccessfulCallbackTimeUnits;
    atomic_uint_fast64_t nearSilenceCallbackCount;
    atomic_uint_fast64_t currentConsecutiveNearSilenceFrameCount;
    atomic_uint_fast64_t maximumConsecutiveNearSilenceFrameCount;
    atomic_uint_fast64_t pcmLeftZeroCrossingCount;
    atomic_uint_fast64_t pcmRightZeroCrossingCount;
    atomic_uint_fast64_t pcmEnvelopeTransitionCount;
    atomic_uint_fast64_t pcmShapeAnomalyCallbackCount;
    atomic_uint_fast64_t pcmBoundaryDiscontinuityCallbackCount;
    atomic_uint_fast32_t lastPCMCallbackMeanMagnitude;
    atomic_bool hasPCMCallbackMeanMagnitude;
    atomic_int_fast32_t lastPCMLeftNonzeroSign;
    atomic_int_fast32_t lastPCMRightNonzeroSign;
    atomic_bool hasPCMCallbackBoundary;
    atomic_int_fast32_t lastPCMLeftSample;
    atomic_int_fast32_t lastPCMRightSample;
    atomic_uint_fast64_t microphoneRealtimeAdmissionCount;
    atomic_uint_fast64_t microphoneDeliveryCallbackCount;
    atomic_uint_fast64_t microphoneDeliveredFrameCount;
    atomic_uint_fast64_t recordingRequestCount;
    atomic_uint_fast64_t recoveryRequestCount;
    atomic_uint_fast64_t recoveryAuthorizationRejectionCount;
    atomic_uint_fast64_t recoveryRebuildCount;
    atomic_uint_fast32_t lastFrameCount;
    atomic_uint_fast32_t lastPeakMagnitude;
    atomic_int_fast32_t lastStatus;
} ASRealtimeDiagnostics;

/// Atomically mirrored lifecycle state keeps diagnostics race-free without ever putting a lock
/// on RemoteIO's render thread. The protocol-facing BOOLs remain owned by WebRTC's ADM thread.
typedef struct ASLifecycleDiagnostics {
    atomic_bool initialized;
    atomic_bool playoutInitialized;
    atomic_bool playing;
    atomic_bool sessionActive;
    atomic_bool remoteIOCreated;
    atomic_bool inputBusEnabled;
    atomic_bool outputBusEnabled;
    atomic_bool recoveryRequired;
    atomic_bool explicitResumeRequired;
    atomic_bool hostedCallMode;
    atomic_bool hostedCallAuthorizationValid;
    atomic_bool hostedCallRecoveryPending;
    atomic_int_fast32_t hostedCallOrigin;
    atomic_uint_fast64_t hostedCallAuthorizationGeneration;
    atomic_uint_fast32_t audioUnitSubType;
    atomic_int_fast32_t failureCode;
    atomic_int_fast32_t lastLifecycleStatus;
} ASLifecycleDiagnostics;

@interface ASIOSMicrophoneAuthorization () {
@public
    ASRealtimeGate _realtimeGate;
    atomic_uint_fast64_t _microphoneRecordingGeneration;
@private
    os_unfair_lock _lock;
#if DEBUG
    dispatch_semaphore_t _debugAuthorizationGateClosureSemaphore;
    atomic_bool _debugAuthorizationGateClosureSignaled;
#endif
}
- (BOOL)performWhileValid:(NS_NOESCAPE dispatch_block_t)operation;
- (void)clearMicrophoneRecordingGeneration;
- (BOOL)bindMicrophoneRecordingGeneration:(uint64_t)recordingGeneration;
@end

@interface ASIOSStereoPlayoutRecoveryAuthorization () {
    os_unfair_lock _lock;
    atomic_bool _valid;
    uint64_t _generation;
    atomic_uint_fast64_t _terminalGeneration;
    atomic_int_fast32_t _terminalOutcome;
}
- (BOOL)performIfValidReturningAcceptance:
    (NS_NOESCAPE BOOL (^)(void))operation;
- (void)publishTerminalOutcomeWhileHoldingLock:
    (ASIOSStereoPlayoutRecoveryTerminalOutcome)outcome;
- (void)reject;
@end

@interface ASIOSHostedCallPlayoutAuthorization () {
    NSUUID *_policyIdentifier;
    ASIOSHostedCallPlayoutOrigin _origin;
    os_unfair_lock _lock;
    atomic_bool _valid;
    atomic_bool _recoveryPending;
    atomic_uint_fast64_t _systemAudioGeneration;
    dispatch_block_t _revocationHandler;
}
- (BOOL)performRecoveryIfValid:(NS_NOESCAPE dispatch_block_t)operation;
- (BOOL)performRecoveryIfValid:(NS_NOESCAPE dispatch_block_t)operation
          consumeRecoveryClaim:(BOOL *)consumeRecoveryClaim;
- (BOOL)performWhileValid:(NS_NOESCAPE dispatch_block_t)operation;
- (BOOL)installRevocationHandlerWhilePerforming:(dispatch_block_t)handler
                          systemAudioGeneration:(uint64_t)generation;
- (void)invalidateWhilePerforming;
- (void)clearRevocationHandler;
@end

@interface ASIOSStereoPlayoutAudioDevice () {
@public
    LKRTCAudioDeviceGetPlayoutDataBlock _playoutBlock;
    LKRTCAudioDeviceDeliverRecordedDataBlock _recordedDataBlock;
    ASRealtimeDiagnostics _realtime;
    ASRealtimeGate _realtimePlayoutDeviceGate;
    ASRealtimeGate _realtimeMicrophoneDeviceGate;
    // The C RemoteIO callbacks borrow only this atomic publication bit. The
    // class itself is private to this implementation file, so making the
    // diagnostics storage visible here does not widen the package API.
    ASLifecycleDiagnostics _lifecycle;
    atomic_ulong _realtimeMicrophoneAuthorizationGate;
    atomic_uint_fast64_t _realtimeMicrophoneRecordingGeneration;
    atomic_uint_fast64_t _realtimeApprovedMicrophoneRecordingGeneration;
    atomic_uint_fast64_t _captureRouteProofGeneration;
    AudioComponentInstance _audioUnit;
    int16_t *_recordingSamples;
    UInt32 _recordingSampleCapacity;
    BOOL _recording;
@private
    atomic_uint_fast64_t _systemAudioGeneration;
    atomic_uint_fast64_t _activeAudioConfigurationGeneration;
    AudioStreamBasicDescription _streamFormat;
    AudioStreamBasicDescription _inputStreamFormat;
    BOOL _initialized;
    BOOL _playoutInitialized;
    BOOL _playing;
    BOOL _audioUnitRunning;
    BOOL _wantsPlayout;
    BOOL _wantsRecording;
    BOOL _sessionActive;
    BOOL _interrupted;
    BOOL _recoveryRequired;
    BOOL _explicitResumeRequired;
    BOOL _inputBusEnabled;
    BOOL _outputBusEnabled;
    BOOL _isRebuilding;
    OSType _audioUnitSubType;
    uint64_t _sessionOwnershipToken;
    uint64_t _routeConfigurationChangeResolverEpoch;
    NSArray<id> *_notificationTokens;
    ASIOSMicrophoneAuthorization *_microphoneAuthorization;
    uint64_t _microphoneRecordingGenerationCounter;
    uint64_t _captureRouteProofGenerationCounter;
    uint64_t _audioConfigurationGenerationCounter;
    atomic_uint_fast64_t _microphoneApprovalConsumedGeneration;
    uint64_t _hostedCallAuthorizationGeneration;
    NSUUID *_hostedCallPolicyIdentifier;
    ASIOSHostedCallPlayoutAuthorization *_hostedCallAuthorization;
    ASIOSHostedCallPlayoutAuthorization *_hostedCallRecoveryInProgressAuthorization;
    os_unfair_lock _expectedMicrophoneRouteChangeLock;
    dispatch_queue_t _expectedMicrophoneRouteChangeEvidenceQueue;
    uint64_t _routeChangeNotificationSequence;
    uint64_t _nonCategoryRouteChangeNotificationSequence;
    uint64_t _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
    uint64_t _expectedMicrophoneRouteChangeTransactionIdentifier;
    uint64_t _expectedMicrophoneRouteChangeMutationSequence;
    NSUInteger _expectedMicrophoneRouteChangeNotificationInFlightCount;
    ASExpectedMicrophoneRouteChangeState _expectedMicrophoneRouteChangeState;
    uint64_t _expectedMicrophoneRouteChangeConfigurationGeneration;
    uint64_t _expectedMicrophoneRouteChangeOwnershipToken;
    uint64_t _expectedMicrophoneRouteChangeSystemAudioGeneration;
    uint64_t _expectedMicrophoneRouteChangeObserverSequenceBaseline;
    uint64_t _expectedMicrophoneRouteChangeDeadlineNanoseconds;
    ASRemoteIOStartSettlement _expectedMicrophoneRouteChangeStartSettlement;
    BOOL _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence;
    NSString *_expectedMicrophoneRouteChangeTransitionCursorFingerprint;
    NSString *_expectedMicrophoneRouteChangeConvergedRouteFingerprint;
    NSString *_expectedMicrophoneRouteChangeOutputFingerprint;
    NSString *_expectedMicrophoneRouteChangeTargetInputIdentifier;
    BOOL _expectedMicrophoneRouteChangeInputRequired;
    BOOL _expectedMicrophoneRouteChangeRequiresPreferredInput;
    dispatch_semaphore_t _expectedMicrophoneRouteChangeSemaphore;
    NSString *_expectedMicrophoneRouteChangeRejectionSnapshot;
#if DEBUG
    os_unfair_lock _debugRealtimeAdmissionLock;
    ASRealtimeGate *_debugAdmittedDeviceGate;
    ASRealtimeGate *_debugAdmittedAuthorizationGate;
    dispatch_semaphore_t _debugDeviceGateClosureSemaphore;
    atomic_bool _debugDeviceGateClosureSignaled;
    BOOL _debugRecoveryHarnessMode;
    BOOL _debugHealthyPlayoutForTesting;
    BOOL _debugHasOutputRouteOverride;
    BOOL _debugHasOutputRoute;
    BOOL _debugCaptureRouteIsBuiltInMicrophone;
    BOOL _debugFailNextHostedCallActivation;
    BOOL _debugOwnsSessionActivation;
    NSUInteger _debugConfigurationOperationCount;
    BOOL _debugHasRecordedAudioPolicyConfiguration;
    NSString *_debugLastConfiguredCategory;
    NSString *_debugLastConfiguredMode;
    AVAudioSessionRouteSharingPolicy _debugLastConfiguredRouteSharingPolicy;
    AVAudioSessionCategoryOptions _debugLastConfiguredCategoryOptions;
    BOOL _debugLastConfiguredInputBusEnabled;
    BOOL _debugLastConfiguredOutputBusEnabled;
    AudioStreamBasicDescription _debugLastConfiguredOutputStreamFormat;
    NSNotification *_debugExpectedCategoryObservationNotification;
    NSString *_debugExpectedCategoryObservationCategory;
    NSString *_debugExpectedCategoryObservationMode;
    AVAudioSessionCategoryOptions
        _debugExpectedCategoryObservationOptions;
    AVAudioSessionRouteSharingPolicy
        _debugExpectedCategoryObservationSharingPolicy;
#endif
}
@property(atomic, strong, nullable) id<LKRTCAudioDeviceDelegate> delegate;
@property(atomic, copy, readwrite, nullable) NSString *lastLifecycleFailureMessage;
- (void)closeAndFenceRealtimeMicrophoneResources;
- (void)closeAndFenceRealtimePlayoutResources;
- (void)closeRealtimeRouteGatesWithoutDraining;
- (dispatch_semaphore_t _Nullable)
    clearExpectedMicrophoneRouteChangeWhileHoldingLock;
- (void)closeRealtimeRouteGatesAndRetireExpectedMicrophoneRouteChangeForSystemEvent;
- (void)scheduleExpectedMicrophoneRouteGateReopenForTransactionIdentifier:
    (uint64_t)transactionIdentifier;
- (void)reopenExpectedMicrophoneRouteGatesForTransactionIdentifier:
    (uint64_t)transactionIdentifier;
- (void)clearCurrentMicrophoneRecordingGeneration;
- (uint64_t)installNextMicrophoneRecordingGeneration;
- (BOOL)microphoneTopologyIsStagedAllowingDebugOverride:
    (BOOL)debugTopologyOverride;
- (BOOL)initializePlayoutForCurrentPolicy;
- (BOOL)startPlayoutForCurrentPolicy;
- (BOOL)configureSessionAndCreateRemoteIO;
- (BOOL)applyAudioPolicyConfiguration:
    (ASAudioPolicyConfiguration)configuration
                              toSession:(AVAudioSession *_Nullable)session
                                  error:(NSError *_Nullable *_Nullable)error;
- (BOOL)publishFinalLiveMicrophoneResourcesWithAuthorization:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization
                                      debugTopologyOverride:(BOOL)debugTopologyOverride;
- (void)failAndRollbackWithCode:(ASIOSStereoPlayoutFailureCode)code
                         status:(int32_t)status
                        message:(NSString *)message;
- (OSStatus)stopAndDisposeAudioUnit;
- (ASOwnedSessionConfigurationFailure)
    activateOwnedSessionAndApplyRoutePreferences:
        (AVAudioSession *)session
                             hostedCallMode:(BOOL)hostedCallMode
                           microphoneEnabled:(BOOL)microphoneEnabled
                       configurationGeneration:
                           (uint64_t)configurationGeneration
                                      error:
                                          (NSError *_Nullable *_Nullable)error;
- (BOOL)deactivateOwnedSessionWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)ownsCurrentSessionActivation;
- (BOOL)sessionOwnershipMatchesToken:(uint64_t)ownershipToken;
- (NSString *)routeTransactionFailureSnapshotForPhase:
    (ASRouteTransactionDiagnosticPhase)phase
                                               session:
                                                   (AVAudioSession *_Nullable)session
                         expectedTransactionIdentifier:
                             (uint64_t)expectedTransactionIdentifier
                           requiredNotificationSequence:
                               (uint64_t)requiredNotificationSequence;
- (BOOL)armExpectedMicrophoneRouteChangeForSession:
    (AVAudioSession *)session
                                      inputRequired:(BOOL)inputRequired
                         configurationGeneration:
                             (uint64_t)configurationGeneration;
- (BOOL)bindExpectedMicrophoneRouteChangeToTargetInput:
    (AVAudioSessionPortDescription *_Nullable)targetInput
                                              ownershipToken:
                                                  (uint64_t)ownershipToken
                                      requirePreferredInput:
                                          (BOOL)requirePreferredInput
                                      configurationGeneration:
                                          (uint64_t)configurationGeneration;
- (BOOL)tryBindExpectedMicrophoneRouteChangeToTargetInput:
    (AVAudioSessionPortDescription *_Nullable)targetInput
                                                 ownershipToken:
                                                     (uint64_t)ownershipToken
                                         requirePreferredInput:
                                             (BOOL)requirePreferredInput
                                         configurationGeneration:
                                             (uint64_t)configurationGeneration;
- (BOOL)waitForExpectedMicrophoneConvergenceForSession:
    (AVAudioSession *)session
                                                targetInput:
                                                    (AVAudioSessionPortDescription *)targetInput
                                     requirePreferredInput:
                                         (BOOL)requirePreferredInput
                                          requireExactChannels:
                                              (BOOL)requireExactChannels
                                configurationGeneration:
                                    (uint64_t)configurationGeneration
                                             ownershipToken:
                                                 (uint64_t)ownershipToken;
- (BOOL)prepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
    (AVAudioSession *)session
                                  configurationGeneration:
                                      (uint64_t)configurationGeneration
                                               ownershipToken:
                                                   (uint64_t)ownershipToken;
- (BOOL)tryPrepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
    (AVAudioSession *)session
                                     configurationGeneration:
                                         (uint64_t)configurationGeneration
                                                  ownershipToken:
                                                      (uint64_t)ownershipToken;
- (BOOL)beginExpectedMicrophoneRouteChangeAudioUnitStartForSession:
    (AVAudioSession *)session;
- (BOOL)markExpectedMicrophoneRouteChangeAudioUnitStartCompleted;
- (BOOL)commitExpectedMicrophoneRouteChangeAfterAudioUnitStartForSession:
    (AVAudioSession *)session;
- (BOOL)publishCommittedExpectedMicrophoneRouteChangePlayout;
- (BOOL)waitForExpectedMicrophoneRouteChangeNotificationsToDrainInState:
    (ASExpectedMicrophoneRouteChangeState)state;
- (BOOL)transitionExpectedMicrophoneRouteChangeForSession:
    (AVAudioSession *)session
                                    transactionIdentifier:
                                        (uint64_t)expectedTransactionIdentifier
                                            expectedState:
                                                (ASExpectedMicrophoneRouteChangeState)expectedState
                                                nextState:
                                                    (ASExpectedMicrophoneRouteChangeState)nextState
                                     requirePreparedRoute:
                                         (BOOL)requirePreparedRoute
                              validatedNotificationSequence:
                                  (uint64_t *_Nullable)validatedNotificationSequence;
- (ASExpectedMicrophoneRouteChangeState)
    expectedMicrophoneRouteChangeState;
- (void)enqueueExpectedMicrophoneRouteChangeNotification:
    (NSNotification *)notification
                                                reason:
                                                    (AVAudioSessionRouteChangeReason)reason
                                      resolverToken:
                                          (ASRouteConfigurationChangeResolverToken)resolverToken;
- (ASExpectedRouteObservationHandling)
    processExpectedMicrophoneRouteChangeObservationWithReason:
    (AVAudioSessionRouteChangeReason)reason
                                      notificationSequence:
                                          (uint64_t)notificationSequence
                                                  snapshot:
                                                      (ASExpectedRouteObservationSnapshot *)snapshot
                                     transactionIdentifier:
                                         (uint64_t)transactionIdentifier
                                                 entryState:
                                                     (ASExpectedMicrophoneRouteChangeState)entryState
                            entryConfigurationGeneration:
                                (uint64_t)entryConfigurationGeneration
                                    entrySystemAudioGeneration:
                                        (uint64_t)entrySystemAudioGeneration
                                   trackedTransaction:
                                       (BOOL)trackedTransaction;
- (void)clearExpectedMicrophoneRouteChange;
- (void)publishFailureCode:(ASIOSStereoPlayoutFailureCode)code
                     status:(int32_t)status
                    message:(NSString *)message;
- (void)clearLifecycleFailure;
- (BOOL)rebuildAfterExplicitRecovery;
- (BOOL)rebuildForCurrentPolicy;
- (BOOL)microphoneShouldBeActive;
- (AVAudioSession *_Nullable)currentAudioSession;
- (uint64_t)advanceSystemAudioGeneration;
- (BOOL)hasOutputRouteForSession:(AVAudioSession *_Nullable)session;
- (BOOL)hostedCallModeIsAuthorized;
- (BOOL)hostedCallOwnershipMatchesAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
                                 policyIdentifier:(NSUUID *)policyIdentifier
                                        generation:(uint64_t)generation;
- (BOOL)hostedCallOriginIsAdmissible:
    (ASIOSHostedCallPlayoutOrigin)origin;
- (void)publishHostedCallLifecycleState;
- (void)retireMicrophoneAuthorizationForHostedCall;
- (void)revokeHostedCallAuthorization;
- (void)hostedCallAuthorizationDidRevoke:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
                             policyIdentifier:(NSUUID *)policyIdentifier
                                    generation:(uint64_t)generation;
- (BOOL)sessionMatchesCurrentPolicy:(AVAudioSession *_Nullable)session;
- (ASHostedCallRecoveryReadiness)hostedCallRecoveryReadinessForAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
                                    expectedSystemAudioGeneration:(uint64_t)generation;
- (void)remainQuiescentAfterHostedCallOwnershipLossWithMessage:
    (NSString *)message;
#if DEBUG
- (void)debugRecordAudioPolicyConfiguration:
    (ASAudioPolicyConfiguration)configuration;
- (NSUInteger)debugConfigurationOperationCountForTesting;
- (NSString *_Nullable)debugLastConfiguredCategoryForTesting;
- (NSString *_Nullable)debugLastConfiguredModeForTesting;
- (NSInteger)debugLastConfiguredRouteSharingPolicyForTesting;
- (NSUInteger)debugLastConfiguredCategoryOptionsForTesting;
- (BOOL)debugLastConfiguredInputBusEnabledForTesting;
- (BOOL)debugLastConfiguredOutputBusEnabledForTesting;
- (AudioStreamBasicDescription)debugLastConfiguredOutputStreamFormatForTesting;
- (void)debugEnableRecoveryHarnessModeForTesting;
- (NSUUID *_Nullable)debugHostedCallPolicyIdentifierForTesting;
- (void)debugMarkInterruptedFailClosedForTesting;
- (void)debugMarkInterruptionEndedFailClosedForTesting;
- (void)debugMarkHealthyPlayoutForTesting;
- (void)debugMarkRouteLossForTesting;
- (void)debugAdvanceSystemAudioGenerationForTesting;
- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available;
- (void)debugSetCaptureRouteBuiltInMicrophoneForTesting:(BOOL)isBuiltIn;
- (void)debugFailNextHostedCallActivationForTesting;
- (BOOL)debugClearRetiresInFlightExpectedRouteObservationForTesting;
- (BOOL)debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting;
- (BOOL)debugRemoteIOStartSettlementProductionStateHoldsForTesting;
- (BOOL)debugConsumedPublicationRetainsRecordedRouteClosureForTesting;
- (BOOL)debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting;
- (BOOL)debugDriveRetiredExpectedCategoryObservationForTestingWithExactPolicy:
    (BOOL)exactPolicy;
#endif
- (void)scheduleSystemEvent:(ASSystemAudioEvent)event
                routeReason:(AVAudioSessionRouteChangeReason)routeReason;
- (void)scheduleRouteChangedSystemEventForReason:
    (AVAudioSessionRouteChangeReason)routeReason
                                  notificationSequence:
                                      (uint64_t)notificationSequence
                          capturedTransactionIdentifier:
                              (uint64_t)capturedTransactionIdentifier
                          capturedSystemAudioGeneration:
                              (uint64_t)capturedSystemAudioGeneration
                                      notification:
                                          (NSNotification *)notification
                                      resolverToken:
                                          (ASRouteConfigurationChangeResolverToken)resolverToken;
- (void)handleSystemEvent:(ASSystemAudioEvent)event
              routeReason:(AVAudioSessionRouteChangeReason)routeReason;
- (void)failClosedForSystemEventWithCode:(ASIOSStereoPlayoutFailureCode)code
                                  message:(NSString *)message;
@end

static void ASZeroAudioBufferList(AudioBufferList *bufferList) {
    if (bufferList == NULL) {
        return;
    }
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static BOOL ASMicrophoneAuthorizationIsValid(
    ASIOSMicrophoneAuthorization *authorization
) {
    return authorization != nil
        && !ASRealtimeGateIsClosed(&authorization->_realtimeGate);
}

@implementation ASIOSMicrophoneAuthorization

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
        ASInitializeRealtimeGateOpen(&_realtimeGate);
        atomic_init(&_microphoneRecordingGeneration, 0);
#if DEBUG
        _debugAuthorizationGateClosureSemaphore = dispatch_semaphore_create(0);
        atomic_init(&_debugAuthorizationGateClosureSignaled, false);
#endif
    }
    return self;
}

- (BOOL)isValid {
    return !ASRealtimeGateIsClosed(&_realtimeGate);
}

- (uint64_t)microphoneRecordingGeneration {
    return atomic_load_explicit(
        &_microphoneRecordingGeneration,
        memory_order_acquire
    );
}

- (void)revoke {
    ASAssertRealtimeGateCanDrain(&_realtimeGate);
    os_unfair_lock_lock(&_lock);
    BOOL didClose = ASCloseRealtimeGate(&_realtimeGate);
#if DEBUG
    if (didClose
        && !atomic_exchange_explicit(
            &_debugAuthorizationGateClosureSignaled,
            true,
            memory_order_acq_rel
        )) {
        dispatch_semaphore_signal(_debugAuthorizationGateClosureSemaphore);
    }
#else
    (void)didClose;
#endif
    ASDrainRealtimeGate(&_realtimeGate);
    atomic_store_explicit(
        &_microphoneRecordingGeneration,
        0,
        memory_order_release
    );
    os_unfair_lock_unlock(&_lock);
}

- (void)clearMicrophoneRecordingGeneration {
    os_unfair_lock_lock(&_lock);
    atomic_store_explicit(
        &_microphoneRecordingGeneration,
        0,
        memory_order_release
    );
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)bindMicrophoneRecordingGeneration:(uint64_t)recordingGeneration {
    if (recordingGeneration == 0) {
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    if (ASRealtimeGateIsClosed(&_realtimeGate)) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    atomic_store_explicit(
        &_microphoneRecordingGeneration,
        recordingGeneration,
        memory_order_release
    );
    os_unfair_lock_unlock(&_lock);
    return YES;
}

#if DEBUG
- (void)debugSetMicrophoneRecordingGenerationForTesting:
    (uint64_t)recordingGeneration {
    os_unfair_lock_lock(&_lock);
    if (!ASRealtimeGateIsClosed(&_realtimeGate)) {
        atomic_store_explicit(
            &_microphoneRecordingGeneration,
            recordingGeneration,
            memory_order_release
        );
    }
    os_unfair_lock_unlock(&_lock);
}
#endif

- (BOOL)performWhileValid:(NS_NOESCAPE dispatch_block_t)operation {
    os_unfair_lock_lock(&_lock);
    if (ASRealtimeGateIsClosed(&_realtimeGate)) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    operation();
    os_unfair_lock_unlock(&_lock);
    return YES;
}

#if DEBUG
- (BOOL)debugBeginRealtimeAdmissionForTesting {
    return ASBeginAuthorizationRealtimeAdmission(&_realtimeGate);
}

- (void)debugEndRealtimeAdmissionForTesting {
    ASEndAuthorizationRealtimeAdmission(&_realtimeGate);
}

- (void)waitForRealtimeGateClosureForTesting {
    dispatch_semaphore_wait(
        _debugAuthorizationGateClosureSemaphore,
        DISPATCH_TIME_FOREVER
    );
}

- (BOOL)performIfValidForTesting:(NS_NOESCAPE dispatch_block_t)operation {
    return [self performWhileValid:operation];
}
#endif

@end

static inline void ASInitializeRealtimeDiagnostics(
    ASRealtimeDiagnostics *diagnostics
) {
    mach_timebase_info_data_t timebase = {0};
    kern_return_t timebaseStatus = mach_timebase_info(&timebase);
    diagnostics->hostTimebaseNumerator =
        timebaseStatus == KERN_SUCCESS && timebase.numer > 0 ? timebase.numer : 1;
    diagnostics->hostTimebaseDenominator =
        timebaseStatus == KERN_SUCCESS && timebase.denom > 0 ? timebase.denom : 1;
    atomic_init(&diagnostics->publicationSequence, 0);
    atomic_init(&diagnostics->callbackCount, 0);
    atomic_init(&diagnostics->frameCount, 0);
    atomic_init(&diagnostics->failureCount, 0);
    atomic_init(&diagnostics->pcmSampleCount, 0);
    atomic_init(&diagnostics->pcmNonzeroSampleCount, 0);
    atomic_init(&diagnostics->pcmAbsoluteSampleSum, 0);
    atomic_init(&diagnostics->pcmLeftAbsoluteSampleSum, 0);
    atomic_init(&diagnostics->pcmRightAbsoluteSampleSum, 0);
    atomic_init(&diagnostics->pcmStereoDifferenceAbsoluteSampleSum, 0);
    atomic_init(&diagnostics->pcmClippedSampleCount, 0);
    atomic_init(&diagnostics->explicitSilenceCallbackCount, 0);
    atomic_init(&diagnostics->callbackGapViolationCount, 0);
    atomic_init(&diagnostics->maximumCallbackGapNanoseconds, 0);
    atomic_init(&diagnostics->lastSuccessfulCallbackTimeUnits, 0);
    atomic_init(&diagnostics->nearSilenceCallbackCount, 0);
    atomic_init(&diagnostics->currentConsecutiveNearSilenceFrameCount, 0);
    atomic_init(&diagnostics->maximumConsecutiveNearSilenceFrameCount, 0);
    atomic_init(&diagnostics->pcmLeftZeroCrossingCount, 0);
    atomic_init(&diagnostics->pcmRightZeroCrossingCount, 0);
    atomic_init(&diagnostics->pcmEnvelopeTransitionCount, 0);
    atomic_init(&diagnostics->pcmShapeAnomalyCallbackCount, 0);
    atomic_init(&diagnostics->pcmBoundaryDiscontinuityCallbackCount, 0);
    atomic_init(&diagnostics->lastPCMCallbackMeanMagnitude, 0);
    atomic_init(&diagnostics->hasPCMCallbackMeanMagnitude, false);
    atomic_init(&diagnostics->lastPCMLeftNonzeroSign, 0);
    atomic_init(&diagnostics->lastPCMRightNonzeroSign, 0);
    atomic_init(&diagnostics->hasPCMCallbackBoundary, false);
    atomic_init(&diagnostics->lastPCMLeftSample, 0);
    atomic_init(&diagnostics->lastPCMRightSample, 0);
    atomic_init(&diagnostics->recordingRequestCount, 0);
    atomic_init(&diagnostics->recoveryRequestCount, 0);
    atomic_init(&diagnostics->recoveryAuthorizationRejectionCount, 0);
    atomic_init(&diagnostics->recoveryRebuildCount, 0);
    atomic_init(&diagnostics->lastFrameCount, 0);
    atomic_init(&diagnostics->lastPeakMagnitude, 0);
    atomic_init(&diagnostics->lastStatus, noErr);
}

static inline void ASUpdateAtomicMaximum(
    atomic_uint_fast64_t *maximum,
    uint64_t candidate
) {
    uint_fast64_t observed = atomic_load_explicit(maximum, memory_order_relaxed);
    while (candidate > observed
           && !atomic_compare_exchange_weak_explicit(
               maximum,
               &observed,
               candidate,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
}

/// RemoteIO has one render writer. Marking its complete evidence transaction odd/even lets a
/// non-realtime diagnostics reader retry instead of accepting fields from two callback epochs.
static inline void ASBeginRealtimePublication(
    ASRealtimeDiagnostics *diagnostics
) {
    atomic_fetch_add_explicit(
        &diagnostics->publicationSequence,
        1,
        memory_order_acq_rel
    );
}

static inline void ASEndRealtimePublication(
    ASRealtimeDiagnostics *diagnostics
) {
    atomic_fetch_add_explicit(
        &diagnostics->publicationSequence,
        1,
        memory_order_release
    );
}

/// Records cadence only for callbacks whose WebRTC playout block completed successfully. The
/// zero timestamp is reserved as the uninitialized sentinel; production monotonic host time and
/// the DEBUG harness both provide nonzero nanoseconds.
static inline void ASRecordSuccessfulCallbackTime(
    ASRealtimeDiagnostics *diagnostics,
    uint64_t monotonicTimeUnits,
    uint32_t nanosecondsNumerator,
    uint32_t nanosecondsDenominator
) {
    if (monotonicTimeUnits == 0 || nanosecondsDenominator == 0) {
        return;
    }
    uint_fast64_t previous = atomic_load_explicit(
        &diagnostics->lastSuccessfulCallbackTimeUnits,
        memory_order_relaxed
    );
    while (monotonicTimeUnits > previous
           && !atomic_compare_exchange_weak_explicit(
               &diagnostics->lastSuccessfulCallbackTimeUnits,
               &previous,
               monotonicTimeUnits,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
    if (previous == 0 || monotonicTimeUnits <= previous) {
        return;
    }
    uint64_t gapUnits = monotonicTimeUnits - previous;
    // Split quotient/remainder avoids a compiler-emitted 128-bit division helper on the realtime
    // path while retaining exact integer conversion for realistic callback gaps.
    uint64_t wholeUnits = gapUnits / nanosecondsDenominator;
    uint64_t remainderUnits = gapUnits % nanosecondsDenominator;
    uint64_t gap = wholeUnits * nanosecondsNumerator
        + (remainderUnits * nanosecondsNumerator) / nanosecondsDenominator;
    ASUpdateAtomicMaximum(&diagnostics->maximumCallbackGapNanoseconds, gap);
    if (gap > ASCallbackGapViolationThresholdNanoseconds) {
        atomic_fetch_add_explicit(
            &diagnostics->callbackGapViolationCount,
            1,
            memory_order_relaxed
        );
    }
}

static inline void ASRecordNearSilenceState(
    ASRealtimeDiagnostics *diagnostics,
    UInt32 frameCount,
    uint64_t sampleCount,
    uint64_t nonzeroSampleCount,
    uint64_t absoluteSampleSum,
    BOOL outputIsSilence
) {
    BOOL insufficientDensity = sampleCount == 0
        || nonzeroSampleCount * 100
            < sampleCount * ASNearSilenceMinimumNonzeroPercent;
    BOOL insufficientMeanMagnitude = sampleCount == 0
        || absoluteSampleSum < sampleCount * ASNearSilenceMinimumMeanMagnitude;
    BOOL nearSilence = outputIsSilence
        || insufficientDensity
        || insufficientMeanMagnitude;
    if (!nearSilence) {
        atomic_store_explicit(
            &diagnostics->currentConsecutiveNearSilenceFrameCount,
            0,
            memory_order_relaxed
        );
        return;
    }

    atomic_fetch_add_explicit(
        &diagnostics->nearSilenceCallbackCount,
        1,
        memory_order_relaxed
    );
    uint64_t consecutiveFrames = atomic_fetch_add_explicit(
        &diagnostics->currentConsecutiveNearSilenceFrameCount,
        frameCount,
        memory_order_relaxed
    ) + frameCount;
    ASUpdateAtomicMaximum(
        &diagnostics->maximumConsecutiveNearSilenceFrameCount,
        consecutiveFrames
    );
}

static inline BOOL ASRecordEnvelopeState(
    ASRealtimeDiagnostics *diagnostics,
    uint64_t sampleCount,
    uint64_t absoluteSampleSum
) {
    uint32_t meanMagnitude = sampleCount == 0
        ? 0
        : (uint32_t)(absoluteSampleSum / sampleCount);
    uint_fast32_t previous = atomic_exchange_explicit(
        &diagnostics->lastPCMCallbackMeanMagnitude,
        meanMagnitude,
        memory_order_relaxed
    );
    bool hadPrevious = atomic_exchange_explicit(
        &diagnostics->hasPCMCallbackMeanMagnitude,
        true,
        memory_order_relaxed
    );
    if (!hadPrevious || previous == 0 || meanMagnitude == 0) {
        return NO;
    }
    uint64_t smaller = MIN((uint64_t)previous, (uint64_t)meanMagnitude);
    uint64_t larger = MAX((uint64_t)previous, (uint64_t)meanMagnitude);
    if (larger * 100 > smaller * ASEnvelopeTransitionRatioPercent) {
        atomic_fetch_add_explicit(
            &diagnostics->pcmEnvelopeTransitionCount,
            1,
            memory_order_relaxed
        );
        return YES;
    }
    return NO;
}

static inline BOOL ASBoundaryJumpExceedsDerivative(
    uint64_t boundaryJump,
    uint64_t internalDerivativeAbsoluteSum,
    uint64_t internalDerivativeCount
) {
    if (boundaryJump == 0 || internalDerivativeCount == 0) {
        return NO;
    }
    if (internalDerivativeAbsoluteSum == 0) {
        return YES;
    }
    return boundaryJump * internalDerivativeCount * 100
        > internalDerivativeAbsoluteSum * ASBoundaryJumpToMeanDerivativePercent;
}

/// Records challenge-specific waveform evidence at the exact PCM boundary supplied to RemoteIO.
/// State is cumulative and intentionally never cleared by a recovery rebuild. Near-silence breaks
/// boundary continuity so silence/resume cannot be misclassified as a phase reset. A deliberate
/// >40% coded level transition is likewise excluded from the boundary counter, while its separate
/// envelope counter remains observable.
static inline void ASRecordWaveformQualityState(
    ASRealtimeDiagnostics *diagnostics,
    uint64_t sampleCount,
    uint64_t nonzeroSampleCount,
    uint64_t absoluteSampleSum,
    uint32_t peakMagnitude,
    BOOL outputIsSilence,
    BOOL envelopeTransition,
    BOOL hasStereoBoundary,
    int32_t firstLeftSample,
    int32_t firstRightSample,
    int32_t lastLeftSample,
    int32_t lastRightSample,
    uint64_t leftDerivativeAbsoluteSum,
    uint64_t rightDerivativeAbsoluteSum,
    uint64_t leftDerivativeCount,
    uint64_t rightDerivativeCount
) {
    BOOL hasMeasurableShape = !outputIsSilence
        && peakMagnitude > 0
        && sampleCount >= ASWaveformShapeMinimumSampleCount;
    if (hasMeasurableShape) {
        uint64_t scaledMagnitudeSum = absoluteSampleSum * 100;
        uint64_t scaledPeakArea = (uint64_t)peakMagnitude * sampleCount;
        if (scaledMagnitudeSum
                < scaledPeakArea * ASWaveformShapeMinimumMeanToPeakPercent
            || scaledMagnitudeSum
                > scaledPeakArea * ASWaveformShapeMaximumMeanToPeakPercent) {
            atomic_fetch_add_explicit(
                &diagnostics->pcmShapeAnomalyCallbackCount,
                1,
                memory_order_relaxed
            );
        }
    }

    BOOL insufficientDensity = sampleCount == 0
        || nonzeroSampleCount * 100
            < sampleCount * ASNearSilenceMinimumNonzeroPercent;
    BOOL insufficientMeanMagnitude = sampleCount == 0
        || absoluteSampleSum < sampleCount * ASNearSilenceMinimumMeanMagnitude;
    BOOL boundaryEligible = hasStereoBoundary
        && !outputIsSilence
        && !insufficientDensity
        && !insufficientMeanMagnitude;
    if (!boundaryEligible) {
        atomic_store_explicit(
            &diagnostics->hasPCMCallbackBoundary,
            false,
            memory_order_relaxed
        );
        return;
    }

    BOOL hadPreviousBoundary = atomic_load_explicit(
        &diagnostics->hasPCMCallbackBoundary,
        memory_order_relaxed
    );
    int32_t previousLeftSample = (int32_t)atomic_load_explicit(
        &diagnostics->lastPCMLeftSample,
        memory_order_relaxed
    );
    int32_t previousRightSample = (int32_t)atomic_load_explicit(
        &diagnostics->lastPCMRightSample,
        memory_order_relaxed
    );
    if (hadPreviousBoundary && !envelopeTransition) {
        int64_t leftJumpSigned = (int64_t)firstLeftSample - previousLeftSample;
        int64_t rightJumpSigned = (int64_t)firstRightSample - previousRightSample;
        uint64_t leftJump = (uint64_t)(
            leftJumpSigned < 0 ? -leftJumpSigned : leftJumpSigned
        );
        uint64_t rightJump = (uint64_t)(
            rightJumpSigned < 0 ? -rightJumpSigned : rightJumpSigned
        );
        if (ASBoundaryJumpExceedsDerivative(
                leftJump,
                leftDerivativeAbsoluteSum,
                leftDerivativeCount
            )
            || ASBoundaryJumpExceedsDerivative(
                rightJump,
                rightDerivativeAbsoluteSum,
                rightDerivativeCount
            )) {
            atomic_fetch_add_explicit(
                &diagnostics->pcmBoundaryDiscontinuityCallbackCount,
                1,
                memory_order_relaxed
            );
        }
    }

    atomic_store_explicit(
        &diagnostics->lastPCMLeftSample,
        lastLeftSample,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &diagnostics->lastPCMRightSample,
        lastRightSample,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &diagnostics->hasPCMCallbackBoundary,
        true,
        memory_order_relaxed
    );
}

/// Measures the exact signed-16-bit interleaved stereo bytes returned by WebRTC to RemoteIO.
/// This is intentionally integer-only, allocation-free, and lock-free because it runs on the
/// realtime render thread. The counters are evidence of PCM at RemoteIO's render-input boundary,
/// before iOS system mixing, route DSP, the DAC, and the speaker; callback/frame demand alone can
/// advance even when a buggy playout block writes silence.
static inline void ASAnalyzeRenderedPCM(
    ASRealtimeDiagnostics *diagnostics,
    const AudioBufferList *outputData,
    UInt32 frameCount,
    AudioUnitRenderActionFlags actionFlags
) {
    BOOL outputIsSilence =
        (actionFlags & kAudioUnitRenderAction_OutputIsSilence) != 0;
    if (outputIsSilence) {
        atomic_fetch_add_explicit(
            &diagnostics->explicitSilenceCallbackCount,
            1,
            memory_order_relaxed
        );
    }
    if (outputData == NULL || frameCount == 0) {
        atomic_store_explicit(&diagnostics->lastPeakMagnitude, 0, memory_order_relaxed);
        atomic_store_explicit(
            &diagnostics->hasPCMCallbackBoundary,
            false,
            memory_order_relaxed
        );
        ASRecordNearSilenceState(
            diagnostics,
            frameCount,
            0,
            0,
            0,
            outputIsSilence
        );
        return;
    }

    uint64_t remainingSamples = (uint64_t)frameCount * ASOutputChannelCount;
    uint64_t sampleCount = 0;
    uint64_t nonzeroSampleCount = 0;
    uint64_t absoluteSampleSum = 0;
    uint64_t leftAbsoluteSampleSum = 0;
    uint64_t rightAbsoluteSampleSum = 0;
    uint64_t stereoDifferenceAbsoluteSampleSum = 0;
    uint64_t clippedSampleCount = 0;
    uint64_t leftZeroCrossingCount = 0;
    uint64_t rightZeroCrossingCount = 0;
    uint32_t peakMagnitude = 0;
    int32_t pendingLeftSample = 0;
    BOOL hasPendingLeftSample = NO;
    int32_t firstLeftSample = 0;
    int32_t firstRightSample = 0;
    int32_t lastLeftSample = 0;
    int32_t lastRightSample = 0;
    BOOL hasLeftSample = NO;
    BOOL hasRightSample = NO;
    uint64_t leftDerivativeAbsoluteSum = 0;
    uint64_t rightDerivativeAbsoluteSum = 0;
    uint64_t leftDerivativeCount = 0;
    uint64_t rightDerivativeCount = 0;
    int32_t lastLeftNonzeroSign = (int32_t)atomic_load_explicit(
        &diagnostics->lastPCMLeftNonzeroSign,
        memory_order_relaxed
    );
    int32_t lastRightNonzeroSign = (int32_t)atomic_load_explicit(
        &diagnostics->lastPCMRightNonzeroSign,
        memory_order_relaxed
    );

    for (UInt32 bufferIndex = 0;
         bufferIndex < outputData->mNumberBuffers && remainingSamples > 0;
         ++bufferIndex) {
        const AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mDataByteSize < sizeof(int16_t)) {
            continue;
        }
        uint64_t availableSamples = buffer->mDataByteSize / sizeof(int16_t);
        uint64_t samplesToRead = MIN(availableSamples, remainingSamples);
        const int16_t *samples = (const int16_t *)buffer->mData;
        for (uint64_t index = 0; index < samplesToRead; ++index) {
            int32_t sample = samples[index];
            uint32_t magnitude = (uint32_t)(sample < 0 ? -sample : sample);
            absoluteSampleSum += magnitude;
            if (magnitude > 0) {
                nonzeroSampleCount += 1;
            }
            if (magnitude >= 32760) {
                clippedSampleCount += 1;
            }
            if (magnitude > peakMagnitude) {
                peakMagnitude = magnitude;
            }
            if ((sampleCount & 1) == 0) {
                leftAbsoluteSampleSum += magnitude;
                pendingLeftSample = sample;
                hasPendingLeftSample = YES;
                if (hasLeftSample) {
                    int32_t derivative = sample - lastLeftSample;
                    leftDerivativeAbsoluteSum += (uint32_t)(
                        derivative < 0 ? -derivative : derivative
                    );
                    leftDerivativeCount += 1;
                } else {
                    firstLeftSample = sample;
                    hasLeftSample = YES;
                }
                lastLeftSample = sample;
                if (sample != 0) {
                    int32_t sign = sample < 0 ? -1 : 1;
                    if (lastLeftNonzeroSign != 0 && sign != lastLeftNonzeroSign) {
                        leftZeroCrossingCount += 1;
                    }
                    lastLeftNonzeroSign = sign;
                }
            } else {
                rightAbsoluteSampleSum += magnitude;
                if (hasRightSample) {
                    int32_t derivative = sample - lastRightSample;
                    rightDerivativeAbsoluteSum += (uint32_t)(
                        derivative < 0 ? -derivative : derivative
                    );
                    rightDerivativeCount += 1;
                } else {
                    firstRightSample = sample;
                    hasRightSample = YES;
                }
                lastRightSample = sample;
                if (hasPendingLeftSample) {
                    int32_t difference = pendingLeftSample - sample;
                    stereoDifferenceAbsoluteSampleSum +=
                        (uint32_t)(difference < 0 ? -difference : difference);
                }
                hasPendingLeftSample = NO;
                if (sample != 0) {
                    int32_t sign = sample < 0 ? -1 : 1;
                    if (lastRightNonzeroSign != 0 && sign != lastRightNonzeroSign) {
                        rightZeroCrossingCount += 1;
                    }
                    lastRightNonzeroSign = sign;
                }
            }
            sampleCount += 1;
        }
        remainingSamples -= samplesToRead;
    }

    atomic_fetch_add_explicit(
        &diagnostics->pcmSampleCount,
        sampleCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmNonzeroSampleCount,
        nonzeroSampleCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmAbsoluteSampleSum,
        absoluteSampleSum,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmLeftAbsoluteSampleSum,
        leftAbsoluteSampleSum,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmRightAbsoluteSampleSum,
        rightAbsoluteSampleSum,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmStereoDifferenceAbsoluteSampleSum,
        stereoDifferenceAbsoluteSampleSum,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmClippedSampleCount,
        clippedSampleCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmLeftZeroCrossingCount,
        leftZeroCrossingCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &diagnostics->pcmRightZeroCrossingCount,
        rightZeroCrossingCount,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &diagnostics->lastPCMLeftNonzeroSign,
        lastLeftNonzeroSign,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &diagnostics->lastPCMRightNonzeroSign,
        lastRightNonzeroSign,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &diagnostics->lastPeakMagnitude,
        peakMagnitude,
        memory_order_relaxed
    );
    BOOL envelopeTransition = ASRecordEnvelopeState(
        diagnostics,
        sampleCount,
        absoluteSampleSum
    );
    ASRecordWaveformQualityState(
        diagnostics,
        sampleCount,
        nonzeroSampleCount,
        absoluteSampleSum,
        peakMagnitude,
        outputIsSilence,
        envelopeTransition,
        hasLeftSample && hasRightSample,
        firstLeftSample,
        firstRightSample,
        lastLeftSample,
        lastRightSample,
        leftDerivativeAbsoluteSum,
        rightDerivativeAbsoluteSum,
        leftDerivativeCount,
        rightDerivativeCount
    );
    ASRecordNearSilenceState(
        diagnostics,
        frameCount,
        sampleCount,
        nonzeroSampleCount,
        absoluteSampleSum,
        outputIsSilence
    );
}

static inline void ASCrossExplicitRecoveryBoundary(
    ASRealtimeDiagnostics *diagnostics
) {
    // RemoteIO diagnostics are lifetime-cumulative across an explicit rebuild.
    (void)diagnostics;
}

#if DEBUG
typedef void (*ASPlayoutPublicationObserver)(
    const ASRealtimeDiagnostics *diagnostics,
    void *context
);

static inline ASIOSStereoPlayoutPublicationSnapshot ASLoadPlayoutPublicationSnapshot(
    const ASRealtimeDiagnostics *diagnostics
) {
    ASIOSStereoPlayoutPublicationSnapshot snapshot = {0};
    for (;;) {
        uint_fast64_t sequenceBefore = atomic_load_explicit(
            &diagnostics->publicationSequence,
            memory_order_acquire
        );
        if ((sequenceBefore & 1) != 0) {
            continue;
        }
    snapshot.callbackCount = atomic_load_explicit(
        &diagnostics->callbackCount,
        memory_order_acquire
    );
    snapshot.frameCount = atomic_load_explicit(
        &diagnostics->frameCount,
        memory_order_relaxed
    );
    snapshot.failureCount = atomic_load_explicit(
        &diagnostics->failureCount,
        memory_order_relaxed
    );
    snapshot.pcmSampleCount = atomic_load_explicit(
        &diagnostics->pcmSampleCount,
        memory_order_relaxed
    );
    snapshot.pcmNonzeroSampleCount = atomic_load_explicit(
        &diagnostics->pcmNonzeroSampleCount,
        memory_order_relaxed
    );
    snapshot.pcmAbsoluteSampleSum = atomic_load_explicit(
        &diagnostics->pcmAbsoluteSampleSum,
        memory_order_relaxed
    );
    snapshot.pcmLeftAbsoluteSampleSum = atomic_load_explicit(
        &diagnostics->pcmLeftAbsoluteSampleSum,
        memory_order_relaxed
    );
    snapshot.pcmRightAbsoluteSampleSum = atomic_load_explicit(
        &diagnostics->pcmRightAbsoluteSampleSum,
        memory_order_relaxed
    );
    snapshot.pcmStereoDifferenceAbsoluteSampleSum = atomic_load_explicit(
        &diagnostics->pcmStereoDifferenceAbsoluteSampleSum,
        memory_order_relaxed
    );
    snapshot.pcmClippedSampleCount = atomic_load_explicit(
        &diagnostics->pcmClippedSampleCount,
        memory_order_relaxed
    );
    snapshot.explicitSilenceCallbackCount = atomic_load_explicit(
        &diagnostics->explicitSilenceCallbackCount,
        memory_order_relaxed
    );
    snapshot.callbackGapViolationCount = atomic_load_explicit(
        &diagnostics->callbackGapViolationCount,
        memory_order_relaxed
    );
    snapshot.maximumCallbackGapNanoseconds = atomic_load_explicit(
        &diagnostics->maximumCallbackGapNanoseconds,
        memory_order_relaxed
    );
    snapshot.nearSilenceCallbackCount = atomic_load_explicit(
        &diagnostics->nearSilenceCallbackCount,
        memory_order_relaxed
    );
    snapshot.currentConsecutiveNearSilenceFrameCount = atomic_load_explicit(
        &diagnostics->currentConsecutiveNearSilenceFrameCount,
        memory_order_relaxed
    );
    snapshot.maximumConsecutiveNearSilenceFrameCount = atomic_load_explicit(
        &diagnostics->maximumConsecutiveNearSilenceFrameCount,
        memory_order_relaxed
    );
    snapshot.pcmLeftZeroCrossingCount = atomic_load_explicit(
        &diagnostics->pcmLeftZeroCrossingCount,
        memory_order_relaxed
    );
    snapshot.pcmRightZeroCrossingCount = atomic_load_explicit(
        &diagnostics->pcmRightZeroCrossingCount,
        memory_order_relaxed
    );
    snapshot.pcmEnvelopeTransitionCount = atomic_load_explicit(
        &diagnostics->pcmEnvelopeTransitionCount,
        memory_order_relaxed
    );
    snapshot.pcmShapeAnomalyCallbackCount = atomic_load_explicit(
        &diagnostics->pcmShapeAnomalyCallbackCount,
        memory_order_relaxed
    );
    snapshot.pcmBoundaryDiscontinuityCallbackCount = atomic_load_explicit(
        &diagnostics->pcmBoundaryDiscontinuityCallbackCount,
        memory_order_relaxed
    );
    snapshot.lastCallbackMeanMagnitude = atomic_load_explicit(
        &diagnostics->lastPCMCallbackMeanMagnitude,
        memory_order_relaxed
    );
    snapshot.lastFrameCount = atomic_load_explicit(
        &diagnostics->lastFrameCount,
        memory_order_relaxed
    );
    snapshot.lastPeakMagnitude = atomic_load_explicit(
        &diagnostics->lastPeakMagnitude,
        memory_order_relaxed
    );
    snapshot.lastStatus = atomic_load_explicit(
        &diagnostics->lastStatus,
        memory_order_relaxed
    );
        uint_fast64_t sequenceAfter = atomic_load_explicit(
            &diagnostics->publicationSequence,
            memory_order_acquire
        );
        if (sequenceBefore == sequenceAfter) {
            break;
        }
    }
    return snapshot;
}

static void ASCapturePlayoutPrePublicationSnapshot(
    const ASRealtimeDiagnostics *diagnostics,
    void *context
) {
    ASIOSStereoPlayoutPublicationSnapshot *snapshot = context;
    *snapshot = ASLoadPlayoutPublicationSnapshot(diagnostics);
}
#endif

static inline void ASPublishPlayoutCallback(
    ASRealtimeDiagnostics *diagnostics,
    UInt32 frameCount,
    OSStatus status
    #if DEBUG
    , ASPlayoutPublicationObserver observer,
    void *observerContext
    #endif
) {
    atomic_fetch_add_explicit(&diagnostics->frameCount, frameCount, memory_order_relaxed);
    atomic_store_explicit(&diagnostics->lastFrameCount, frameCount, memory_order_relaxed);
    atomic_store_explicit(&diagnostics->lastStatus, status, memory_order_relaxed);
    if (status != noErr) {
        atomic_fetch_add_explicit(&diagnostics->failureCount, 1, memory_order_relaxed);
    }
    #if DEBUG
    if (observer != NULL) {
        observer(diagnostics, observerContext);
    }
    #endif
    atomic_fetch_add_explicit(&diagnostics->callbackCount, 1, memory_order_release);
}

static atomic_uint_fast64_t ASNextPlayoutRecoveryAuthorizationGeneration =
    ATOMIC_VAR_INIT(0);

static uint64_t ASAllocatePlayoutRecoveryAuthorizationGeneration(void) {
    uint64_t generation = atomic_fetch_add_explicit(
        &ASNextPlayoutRecoveryAuthorizationGeneration,
        1,
        memory_order_relaxed
    ) + 1;
    if (generation == 0) {
        generation = atomic_fetch_add_explicit(
            &ASNextPlayoutRecoveryAuthorizationGeneration,
            1,
            memory_order_relaxed
        ) + 1;
    }
    return generation;
}

@implementation ASIOSStereoPlayoutRecoveryAuthorization

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
        atomic_init(&_valid, true);
        _generation =
            ASAllocatePlayoutRecoveryAuthorizationGeneration();
        atomic_init(&_terminalGeneration, 0);
        atomic_init(
            &_terminalOutcome,
            ASIOSStereoPlayoutRecoveryTerminalOutcomePending
        );
    }
    return self;
}

- (uint64_t)generation {
    return _generation;
}

- (uint64_t)terminalGeneration {
    return atomic_load_explicit(
        &_terminalGeneration,
        memory_order_acquire
    );
}

- (ASIOSStereoPlayoutRecoveryTerminalOutcome)terminalOutcome {
    return (ASIOSStereoPlayoutRecoveryTerminalOutcome)
        atomic_load_explicit(&_terminalOutcome, memory_order_acquire);
}

- (void)publishTerminalOutcomeWhileHoldingLock:
    (ASIOSStereoPlayoutRecoveryTerminalOutcome)outcome {
    if (atomic_load_explicit(
            &_terminalGeneration,
            memory_order_acquire
        ) != 0) {
        return;
    }
    atomic_store_explicit(&_terminalOutcome, outcome, memory_order_relaxed);
    atomic_store_explicit(
        &_terminalGeneration,
        _generation,
        memory_order_release
    );
    atomic_store_explicit(&_valid, false, memory_order_release);
}

- (BOOL)isValid {
    // Status polling can occur on MainActor while the native ADM thread performs a rebuild.
    // The ownership lock remains the revocation barrier, but observing pending/completed state
    // must never block the app UI behind AVAudioSession or RemoteIO work.
    return atomic_load_explicit(&_valid, memory_order_acquire);
}

- (void)revoke {
    os_unfair_lock_lock(&_lock);
    if (atomic_load_explicit(&_valid, memory_order_acquire)) {
        [self publishTerminalOutcomeWhileHoldingLock:
            ASIOSStereoPlayoutRecoveryTerminalOutcomeRevoked];
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)performIfValid:(NS_NOESCAPE dispatch_block_t)operation {
    return [self performIfValidReturningAcceptance:^BOOL{
        operation();
        return YES;
    }];
}

- (BOOL)performIfValidReturningAcceptance:
    (NS_NOESCAPE BOOL (^)(void))operation {
    os_unfair_lock_lock(&_lock);
    if (!atomic_load_explicit(&_valid, memory_order_acquire)) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    BOOL accepted = operation();
    [self publishTerminalOutcomeWhileHoldingLock:
        accepted
            ? ASIOSStereoPlayoutRecoveryTerminalOutcomeAccepted
            : ASIOSStereoPlayoutRecoveryTerminalOutcomeRejected];
    os_unfair_lock_unlock(&_lock);
    return accepted;
}

- (void)reject {
    os_unfair_lock_lock(&_lock);
    if (atomic_load_explicit(&_valid, memory_order_acquire)) {
        [self publishTerminalOutcomeWhileHoldingLock:
            ASIOSStereoPlayoutRecoveryTerminalOutcomeRejected];
    }
    os_unfair_lock_unlock(&_lock);
}

#if DEBUG
- (BOOL)debugRejectIfValidForTesting {
    return [self performIfValidReturningAcceptance:^BOOL{
        return NO;
    }];
}
#endif

@end

@implementation ASIOSHostedCallPlayoutAuthorization

- (instancetype)initWithPolicyIdentifier:(NSUUID *)policyIdentifier
                                  origin:(ASIOSHostedCallPlayoutOrigin)origin {
    self = [super init];
    if (self == nil || policyIdentifier == nil) {
        return nil;
    }

    _policyIdentifier = [policyIdentifier copy];
    _origin = origin;
    _lock = OS_UNFAIR_LOCK_INIT;
    atomic_init(&_valid, true);
    atomic_init(&_recoveryPending, true);
    atomic_init(&_systemAudioGeneration, 0);
    return self;
}

- (NSUUID *)policyIdentifier {
    return _policyIdentifier;
}

- (ASIOSHostedCallPlayoutOrigin)origin {
    return _origin;
}

- (BOOL)isValid {
    return atomic_load_explicit(&_valid, memory_order_acquire);
}

- (BOOL)isRecoveryPending {
    return atomic_load_explicit(&_recoveryPending, memory_order_acquire);
}

- (uint64_t)systemAudioGeneration {
    return atomic_load_explicit(&_systemAudioGeneration, memory_order_acquire);
}

- (void)revoke {
    dispatch_block_t handler = nil;
    os_unfair_lock_lock(&_lock);
    BOOL wasValid = atomic_load_explicit(&_valid, memory_order_acquire);
    atomic_store_explicit(&_valid, false, memory_order_release);
    atomic_store_explicit(&_recoveryPending, false, memory_order_release);
    if (wasValid) {
        handler = _revocationHandler;
    }
    _revocationHandler = nil;
    os_unfair_lock_unlock(&_lock);

    if (handler != nil) {
        handler();
    }
}

- (BOOL)performRecoveryIfValid:(NS_NOESCAPE dispatch_block_t)operation
          consumeRecoveryClaim:(BOOL *)consumeRecoveryClaim {
    os_unfair_lock_lock(&_lock);
    if (!atomic_load_explicit(&_valid, memory_order_acquire)
        || !atomic_load_explicit(&_recoveryPending, memory_order_acquire)) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }

    operation();
    BOOL didConsumeRecoveryClaim = *consumeRecoveryClaim;
    if (didConsumeRecoveryClaim) {
        atomic_store_explicit(&_recoveryPending, false, memory_order_release);
    }
    os_unfair_lock_unlock(&_lock);
    return didConsumeRecoveryClaim;
}

- (BOOL)performRecoveryIfValid:(NS_NOESCAPE dispatch_block_t)operation {
    BOOL consumeRecoveryClaim = YES;
    return [self performRecoveryIfValid:operation
                   consumeRecoveryClaim:&consumeRecoveryClaim];
}

- (BOOL)performWhileValid:(NS_NOESCAPE dispatch_block_t)operation {
    os_unfair_lock_lock(&_lock);
    if (!atomic_load_explicit(&_valid, memory_order_acquire)
        || operation == nil) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }

    operation();
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (BOOL)installRevocationHandlerWhilePerforming:(dispatch_block_t)handler
                          systemAudioGeneration:(uint64_t)generation {
    if (generation == 0
        || !atomic_load_explicit(&_valid, memory_order_acquire)
        || !atomic_load_explicit(&_recoveryPending, memory_order_acquire)) {
        return NO;
    }

    uint64_t existingGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    if (existingGeneration != 0 && existingGeneration != generation) {
        return NO;
    }

    atomic_store_explicit(
        &_systemAudioGeneration,
        generation,
        memory_order_release
    );
    _revocationHandler = [handler copy];
    return YES;
}

- (void)invalidateWhilePerforming {
    atomic_store_explicit(&_valid, false, memory_order_release);
    atomic_store_explicit(&_recoveryPending, false, memory_order_release);
    _revocationHandler = nil;
}

- (void)clearRevocationHandler {
    os_unfair_lock_lock(&_lock);
    _revocationHandler = nil;
    os_unfair_lock_unlock(&_lock);
}

#if DEBUG
- (BOOL)performRecoveryIfValidForTesting:(NS_NOESCAPE dispatch_block_t)operation {
    return [self performRecoveryIfValid:operation];
}

- (BOOL)performRecoveryIfValidForTestingWithSystemAudioGeneration:(uint64_t)systemAudioGeneration
                                                revocationHandler:(dispatch_block_t)revocationHandler
                                                         operation:(NS_NOESCAPE dispatch_block_t)operation {
    if (systemAudioGeneration == 0
        || revocationHandler == nil
        || operation == nil) {
        return NO;
    }

    __block BOOL generationInstalled = NO;
    return [self performRecoveryIfValid:^{
        generationInstalled = [self
            installRevocationHandlerWhilePerforming:revocationHandler
                              systemAudioGeneration:systemAudioGeneration];
        if (!generationInstalled) {
            return;
        }

        operation();
    }
                   consumeRecoveryClaim:&generationInstalled];
}
#endif

@end

#if DEBUG
@interface ASIOSStereoPlayoutPublicationTestHarness () {
    ASRealtimeDiagnostics _realtime;
    ASIOSStereoPlayoutPublicationSnapshot _prePublicationSnapshot;
}
@end

@implementation ASIOSStereoPlayoutPublicationTestHarness

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    ASInitializeRealtimeDiagnostics(&_realtime);
    _prePublicationSnapshot = (ASIOSStereoPlayoutPublicationSnapshot){0};
    return self;
}

- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                status:(int32_t)status {
    ASPublishPlayoutCallback(
        &_realtime,
        frameCount,
        status,
        ASCapturePlayoutPrePublicationSnapshot,
        &_prePublicationSnapshot
    );
}

- (void)analyzePCM16Samples:(NSData *)samples
             outputIsSilence:(BOOL)outputIsSilence {
    AudioBufferList output = {0};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = ASOutputChannelCount;
    output.mBuffers[0].mDataByteSize = (UInt32)samples.length;
    output.mBuffers[0].mData = (void *)samples.bytes;
    ASBeginRealtimePublication(&_realtime);
    ASAnalyzeRenderedPCM(
        &_realtime,
        &output,
        (UInt32)(samples.length / (ASOutputChannelCount * sizeof(int16_t))),
        outputIsSilence ? kAudioUnitRenderAction_OutputIsSilence : 0
    );
    ASEndRealtimePublication(&_realtime);
}

- (void)recordSuccessfulCallbackAtMonotonicTimeNanoseconds:(uint64_t)nanoseconds {
    ASBeginRealtimePublication(&_realtime);
    ASRecordSuccessfulCallbackTime(&_realtime, nanoseconds, 1, 1);
    ASEndRealtimePublication(&_realtime);
}

- (void)markRecoveryBoundary {
    ASCrossExplicitRecoveryBoundary(&_realtime);
}

- (ASIOSStereoPlayoutPublicationSnapshot)prePublicationSnapshot {
    return _prePublicationSnapshot;
}

- (ASIOSStereoPlayoutPublicationSnapshot)snapshot {
    return ASLoadPlayoutPublicationSnapshot(&_realtime);
}

@end

@interface ASIOSStereoPlayoutRecoveryHarnessDelegate : NSObject <LKRTCAudioDeviceDelegate>
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *queuedOperations;
- (nullable dispatch_block_t)takeNextOperation;
@end

@implementation ASIOSStereoPlayoutRecoveryHarnessDelegate

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _queuedOperations = [NSMutableArray array];
    }
    return self;
}

- (LKRTCAudioDeviceDeliverRecordedDataBlock)deliverRecordedData {
    return ^OSStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timestamp,
        NSInteger inputBusNumber,
        UInt32 frameCount,
        const AudioBufferList *inputData,
        void *renderContext,
        LKRTCAudioDeviceRenderRecordedDataBlock renderBlock
    ) {
        return noErr;
    };
}

- (double)preferredInputSampleRate { return ASSampleRate; }
- (NSTimeInterval)preferredInputIOBufferDuration { return ASIOBufferDuration; }
- (double)preferredOutputSampleRate { return ASSampleRate; }
- (NSTimeInterval)preferredOutputIOBufferDuration { return ASIOBufferDuration; }

- (LKRTCAudioDeviceGetPlayoutDataBlock)getPlayoutData {
    return ^OSStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp *timestamp,
        NSInteger inputBusNumber,
        UInt32 frameCount,
        AudioBufferList *outputData
    ) {
        return noErr;
    };
}

- (void)notifyAudioInputParametersChange {}
- (void)notifyAudioOutputParametersChange {}
- (void)notifyAudioInputInterrupted {}
- (void)notifyAudioOutputInterrupted {}

- (void)dispatchAsync:(dispatch_block_t)block {
    @synchronized (self) {
        [self.queuedOperations addObject:[block copy]];
    }
}

- (void)dispatchSync:(dispatch_block_t)block {
    block();
}

- (nullable dispatch_block_t)takeNextOperation {
    @synchronized (self) {
        if (self.queuedOperations.count == 0) {
            return nil;
        }
        dispatch_block_t operation = self.queuedOperations.firstObject;
        [self.queuedOperations removeObjectAtIndex:0];
        return operation;
    }
}

@end

@interface ASAudioSessionChannelPreferenceTestDouble
    : NSObject <ASAudioSessionChannelPreferenceConfiguring>
@property(nonatomic) NSInteger maximumInputNumberOfChannels;
@property(nonatomic) NSInteger maximumOutputNumberOfChannels;
@property(nonatomic) NSInteger inputNumberOfChannels;
@property(nonatomic) NSInteger outputNumberOfChannels;
@property(nonatomic, strong) NSMutableArray<NSString *> *operations;
@end

@implementation ASAudioSessionChannelPreferenceTestDouble

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _operations = [NSMutableArray array];
    }
    return self;
}

- (BOOL)setPreferredInputNumberOfChannels:(NSInteger)count
                                    error:(NSError **)error {
    [self.operations addObject:[NSString stringWithFormat:@"input=%ld", (long)count]];
    self.inputNumberOfChannels = count;
    return YES;
}

- (BOOL)setPreferredOutputNumberOfChannels:(NSInteger)count
                                     error:(NSError **)error {
    [self.operations addObject:[NSString stringWithFormat:@"output=%ld", (long)count]];
    self.outputNumberOfChannels = count;
    return YES;
}

@end

@interface ASIOSStereoPlayoutRecoveryTestHarness ()
@property(nonatomic, strong) ASIOSStereoPlayoutAudioDevice *device;
@property(nonatomic, strong) ASIOSStereoPlayoutRecoveryHarnessDelegate *delegate;
@property(nonatomic, copy) NSArray<NSString *> *lastChannelPreferenceOperations;
@end

@implementation ASIOSStereoPlayoutRecoveryTestHarness

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _device = [[ASIOSStereoPlayoutAudioDevice alloc] init];
    _delegate = [[ASIOSStereoPlayoutRecoveryHarnessDelegate alloc] init];
    _lastChannelPreferenceOperations = @[];
    [_device debugEnableRecoveryHarnessModeForTesting];
    if (![_device initializeWithDelegate:_delegate]) {
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self.device terminateDevice];
}

- (ASIOSStereoPlayoutDiagnostics)diagnostics {
    return self.device.diagnostics;
}

- (NSUInteger)queuedOperationCount {
    @synchronized (self.delegate) {
        return self.delegate.queuedOperations.count;
    }
}

- (BOOL)debugApplyActiveChannelPreferencesForTestingWithSessionActive:
    (BOOL)sessionActive
                                       maximumInputChannels:
    (NSInteger)maximumInputChannels
                                      maximumOutputChannels:
    (NSInteger)maximumOutputChannels
                                            microphoneEnabled:
    (BOOL)microphoneEnabled {
    ASAudioSessionChannelPreferenceTestDouble *session =
        [[ASAudioSessionChannelPreferenceTestDouble alloc] init];
    session.maximumInputNumberOfChannels = maximumInputChannels;
    session.maximumOutputNumberOfChannels = maximumOutputChannels;
    ASActiveChannelPreferenceFailure failure = ASApplyActiveChannelPreferences(
        session,
        sessionActive,
        microphoneEnabled,
        nil
    );
    self.lastChannelPreferenceOperations = [session.operations copy];
    return failure == ASActiveChannelPreferenceFailureNone;
}

- (ASIOSExpectedRouteChangeDisposition)
    debugClassifyExpectedRouteChangeForTesting:
        (ASIOSExpectedRouteChangeTestScenario)scenario {
    ASExpectedRouteChangeEvidence evidence = {
        .state = ASExpectedMicrophoneRouteChangeStatePending,
        .reason = AVAudioSessionRouteChangeReasonRouteConfigurationChange,
        .sequenceAdvanced = YES,
        .withinDeadline = YES,
        .configurationGenerationMatches = YES,
        .systemAudioGenerationMatches = YES,
        .fingerprintsArePresent = YES,
        .previousFingerprintWasObserved = YES,
        .policyIsExact = YES,
        .ownershipIsBound = YES,
        .ownershipMatches = YES,
        .sessionActive = YES,
        .recoveryRequired = NO,
        .explicitResumeRequired = NO,
        .currentRouteMatchesConvergedRoute = YES,
        .outputIsExact = YES,
        .channelsAreExact = YES,
        .targetInputIsExact = YES,
        .preferredInputIsExact = YES,
    };
    switch (scenario) {
        case ASIOSExpectedRouteChangeTestScenarioPendingActivation:
            evidence.ownershipIsBound = NO;
            evidence.ownershipMatches = NO;
            evidence.sessionActive = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingBound:
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingCategory:
            evidence.reason = AVAudioSessionRouteChangeReasonCategoryChange;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingOverride:
            evidence.reason = AVAudioSessionRouteChangeReasonOverride;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingWrongPreviousRoute:
            evidence.previousFingerprintWasObserved = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingWrongGeneration:
            evidence.configurationGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingWrongOwnership:
            evidence.ownershipMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedDuplicate:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedChangedRoute:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.currentRouteMatchesConvergedRoute = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedRecoveryRequired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.recoveryRequired = YES;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedExpired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.withinDeadline = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingCoalescedSkippedIntermediate:
            // Models A -> B -> C where the first callback reports previous A with live current C,
            // then the second callback reports unseen previous B. The chain intentionally fails
            // closed rather than claiming provenance for a route it never observed.
            evidence.previousFingerprintWasObserved = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingExpired:
            evidence.withinDeadline = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingSequenceNotAdvanced:
            evidence.sequenceAdvanced = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingWrongSystemGeneration:
            evidence.systemAudioGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingWrongPolicy:
            evidence.policyIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingMissingFingerprint:
            evidence.fingerprintsArePresent = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedWrongOwnership:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.ownershipMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedInactive:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.sessionActive = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedOutputMissing:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.outputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedChannelMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.channelsAreExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedTargetMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.targetInputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedPreferredMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.preferredInputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedWrongSystemGeneration:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.systemAudioGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedWrongGeneration:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.configurationGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedPreviousUnseen:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.previousFingerprintWasObserved = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedExplicitResumeRequired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.explicitResumeRequired = YES;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPreparedExact:
            evidence.state = ASExpectedMicrophoneRouteChangeStatePrepared;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPreparedChangedRoute:
            evidence.state = ASExpectedMicrophoneRouteChangeStatePrepared;
            evidence.currentRouteMatchesConvergedRoute = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingChangedRoute:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.currentRouteMatchesConvergedRoute = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingWrongOwnership:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.ownershipMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingRecoveryRequired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.recoveryRequired = YES;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingOldDeviceUnavailable:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.reason =
                AVAudioSessionRouteChangeReasonOldDeviceUnavailable;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingCategory:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.reason = AVAudioSessionRouteChangeReasonCategoryChange;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingChannelMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.channelsAreExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingCoalescedExactRoute:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.previousFingerprintWasObserved = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingOutputChanged:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.outputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingInactive:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.sessionActive = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingWrongGeneration:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.configurationGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingWrongSystemGeneration:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.systemAudioGenerationMatches = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingTargetMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.targetInputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingPreferredMismatch:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.preferredInputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioStartingExplicitResumeRequired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateStarting;
            evidence.explicitResumeRequired = YES;
            break;
        case ASIOSExpectedRouteChangeTestScenarioPendingOutputChanged:
            evidence.outputIsExact = NO;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedStartSettlementCoalescedExactRoute:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.previousFingerprintWasObserved = NO;
            evidence.remoteIOStartSettlementProvenanceMatches = YES;
            break;
        case ASIOSExpectedRouteChangeTestScenarioConvergedStartSettlementExpired:
            evidence.state = ASExpectedMicrophoneRouteChangeStateConsumed;
            evidence.previousFingerprintWasObserved = NO;
            evidence.remoteIOStartSettlementProvenanceMatches = NO;
            break;
    }
    return ASClassifyExpectedRouteChangeEvidence(evidence);
}

- (BOOL)debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting {
    return [self.device
        debugRemoteIOStartSettlementProductionStateHoldsForTesting];
}

- (BOOL)debugExpectedCategoryObservationIsAbsorbedForTesting:
    (ASIOSExpectedCategoryObservationTestScenario)scenario {
    BOOL trackedTransaction = YES;
    BOOL inputRequired = YES;
    NSString *category = AVAudioSessionCategoryPlayAndRecord;
    NSString *mode = AVAudioSessionModeDefault;
    AVAudioSessionCategoryOptions options =
        ASIPhoneMicrophoneCategoryOptions();
    AVAudioSessionRouteSharingPolicy sharingPolicy =
        AVAudioSessionRouteSharingPolicyDefault;
    uint64_t activeConfigurationGeneration = 11;
    uint64_t observedSystemAudioGeneration = 41;
    uint64_t notificationSequence = 73;
    uint64_t observedAtNanoseconds = 1000;
    uint64_t deadlineNanoseconds = 2000;

    switch (scenario) {
        case ASIOSExpectedCategoryObservationTestScenarioMicrophoneExact:
            break;
        case ASIOSExpectedCategoryObservationTestScenarioOutputOnlyExact:
            inputRequired = NO;
            category = AVAudioSessionCategoryPlayback;
            options = 0;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioUntracked:
            trackedTransaction = NO;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioWrongOptions:
            options = AVAudioSessionCategoryOptionDefaultToSpeaker;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioWrongMode:
            mode = AVAudioSessionModeVoiceChat;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioWrongSharingPolicy:
            sharingPolicy = AVAudioSessionRouteSharingPolicyLongFormAudio;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioWrongConfigurationGeneration:
            activeConfigurationGeneration = 12;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioWrongSystemAudioGeneration:
            observedSystemAudioGeneration = 42;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioSequenceNotAdvanced:
            notificationSequence = 72;
            break;
        case ASIOSExpectedCategoryObservationTestScenarioExpired:
            observedAtNanoseconds = 2001;
            break;
    }

    return ASExpectedCategoryObservationMatchesCapturedPolicy(
        AVAudioSessionRouteChangeReasonCategoryChange,
        trackedTransaction,
        ASExpectedMicrophoneRouteChangeStatePending,
        71,
        11,
        activeConfigurationGeneration,
        41,
        observedSystemAudioGeneration,
        notificationSequence,
        72,
        observedAtNanoseconds,
        deadlineNanoseconds,
        inputRequired,
        category,
        mode,
        options,
        sharingPolicy
    );
}

- (BOOL)debugDriveRetiredExpectedCategoryObservationForTestingWithExactPolicy:
    (BOOL)exactPolicy {
    return [self.device
        debugDriveRetiredExpectedCategoryObservationForTestingWithExactPolicy:
            exactPolicy];
}

- (BOOL)debugSupersededRouteObservationIsSuppressedForTestingWithOldDeviceUnavailable:
    (BOOL)oldDeviceUnavailable {
    AVAudioSessionRouteChangeReason reason = oldDeviceUnavailable
        ? AVAudioSessionRouteChangeReasonOldDeviceUnavailable
        : AVAudioSessionRouteChangeReasonRouteConfigurationChange;
    return ASShouldSuppressSupersededRouteConfigurationObservation(
        reason,
        41,
        7,
        ASExpectedMicrophoneRouteChangeStatePending,
        8,
        41
    );
}

- (BOOL)debugRetiredSystemGenerationRouteObservationIsSuppressedForTestingWithOldDeviceUnavailable:
    (BOOL)oldDeviceUnavailable {
    AVAudioSessionRouteChangeReason reason = oldDeviceUnavailable
        ? AVAudioSessionRouteChangeReasonOldDeviceUnavailable
        : AVAudioSessionRouteChangeReasonRouteConfigurationChange;
    return ASShouldSuppressRetiredSystemAudioGenerationObservation(
        reason,
        41,
        42
    );
}

- (BOOL)debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting {
    return ASShouldScheduleRouteGateClosureResolution(
        YES,
        0,
        ASExpectedMicrophoneRouteChangeStateConsumed,
        YES
    );
}

- (BOOL)debugRecordedConsumedRouteClosureUsesFreshRouteForTesting {
    BOOL staleIngressSnapshotWasExact = NO;
    BOOL freshDeviceQueueSnapshotIsExact = YES;
    uint64_t validatedNotificationSequence = 72;
    uint64_t currentNotificationSequence = 72;
    BOOL scheduled = ASShouldScheduleRouteGateClosureResolution(
        YES,
        0,
        ASExpectedMicrophoneRouteChangeStateConsumed,
        YES
    );
    // The stale ingress value is intentionally not consulted. Resolution is
    // driven by the fresh device-queue sample plus its sequence fence.
    (void)staleIngressSnapshotWasExact;
    return scheduled
        && freshDeviceQueueSnapshotIsExact
        && ASValidatedRouteNotificationSequenceIsCurrent(
            validatedNotificationSequence,
            currentNotificationSequence
        );
}

- (BOOL)debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting {
    uint64_t validatedNotificationSequence = 72;
    BOOL stableSequenceWouldReopen =
        ASValidatedRouteNotificationSequenceIsCurrent(
            validatedNotificationSequence,
            72
        );
    BOOL advancedSequenceWouldReopen =
        ASValidatedRouteNotificationSequenceIsCurrent(
            validatedNotificationSequence,
            73
        );
    return stableSequenceWouldReopen && !advancedSequenceWouldReopen;
}

- (BOOL)debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting {
    ASDebugAudioUnitStopInvocationCount = 0;
    BOOL running = YES;
    AudioUnit sentinel = (AudioUnit)(uintptr_t)1;
    OSStatus runningStatus = ASStopAudioUnitIfRunning(
        sentinel,
        &running,
        ASDebugAudioUnitStop
    );
    BOOL stoppedRunningUnit = runningStatus == noErr
        && !running
        && ASDebugAudioUnitStopInvocationCount == 1;

    OSStatus stoppedStatus = ASStopAudioUnitIfRunning(
        sentinel,
        &running,
        ASDebugAudioUnitStop
    );
    return stoppedRunningUnit
        && stoppedStatus == noErr
        && !running
        && ASDebugAudioUnitStopInvocationCount == 1;
}

- (BOOL)debugRouteEvidenceOwnsMicrophonePublicationClosureForTestingWithRecordedClosure:
    (BOOL)recordedClosure
                                                                         inFlightCount:
                                                                             (NSUInteger)inFlightCount {
    return ASRouteEvidenceOwnsDeviceGateClosure(
        recordedClosure,
        inFlightCount
    );
}

- (BOOL)debugTrackedCategoryObservationOwnsRouteClosureForTesting {
    return ASMustCloseRealtimeRouteGatesForObservation(
        AVAudioSessionRouteChangeReasonCategoryChange,
        YES,
        YES
    );
}

- (BOOL)debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting {
    return !ASMustCloseRealtimeRouteGatesForObservation(
        AVAudioSessionRouteChangeReasonCategoryChange,
        YES,
        NO
    );
}

- (BOOL)debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting {
    [self.device debugMarkHealthyPlayoutForTesting];
    NSUInteger queuedBefore = self.queuedOperationCount;
    BOOL retained = [self.device
        debugConsumedPublicationRetainsRecordedRouteClosureForTesting];
    return retained && self.queuedOperationCount == queuedBefore + 1;
}

- (BOOL)debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting {
    BOOL exactWouldPublish = ASFinalMicrophoneRouteValidationIsCurrent(
        71,
        71,
        19,
        19,
        43,
        43,
        0,
        ASExpectedMicrophoneRouteChangeStateConsumed
    );
    BOOL delayedCategoryOrRouteWouldPublish =
        ASFinalMicrophoneRouteValidationIsCurrent(
            71,
            71,
            19,
            19,
            43,
            44,
            1,
            ASExpectedMicrophoneRouteChangeStateConsumed
        );
    BOOL processedDelayedEvidenceWouldPublish =
        ASFinalMicrophoneRouteValidationIsCurrent(
            71,
            71,
            19,
            20,
            43,
            44,
            0,
            ASExpectedMicrophoneRouteChangeStateConsumed
        );
    return exactWouldPublish
        && !delayedCategoryOrRouteWouldPublish
        && !processedDelayedEvidenceWouldPublish;
}

- (BOOL)debugRouteLockedOwnershipSnapshotComparatorForTesting {
    // Model AVAudioSession synchronously entering a route observer while the
    // ownership mutation lock is held. The observer-side predicate must remain
    // a pure snapshot comparison: taking a second lock here would deadlock the
    // real ownership -> AVAudioSession -> route-observer call chain.
    os_unfair_lock fakeOwnershipMutationLock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&fakeOwnershipMutationLock);
    BOOL synchronousObserverReturned =
        ASBoundOwnershipTokenMatchesSnapshot(91, 91);
    os_unfair_lock_unlock(&fakeOwnershipMutationLock);
    return synchronousObserverReturned
        && !ASBoundOwnershipTokenMatchesSnapshot(0, 0)
        && !ASBoundOwnershipTokenMatchesSnapshot(91, 92);
}

- (BOOL)debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting {
    return [self.device
        debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting];
}

- (BOOL)debugClearRetiresInFlightExpectedRouteObservationForTesting {
    return [self.device
        debugClearRetiresInFlightExpectedRouteObservationForTesting];
}

- (BOOL)debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting {
    return [self.device
        debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting];
}

- (NSString *)debugStructuredRouteTransactionFailureSnapshotForTesting {
    ASRouteTransactionFailureSnapshot *snapshot =
        [[ASRouteTransactionFailureSnapshot alloc] init];
    snapshot.phase = @"fresh-reopen";
    snapshot.state = @"consumed";
    snapshot.transactionIdentifier = 71;
    snapshot.expectedTransactionIdentifier = 71;
    snapshot.notificationSequence = 73;
    snapshot.observerSequenceBaseline = 68;
    snapshot.requiredNotificationSequence = 72;
    snapshot.notificationInFlightCount = 0;
    snapshot.boundConfigurationGeneration = 11;
    snapshot.currentConfigurationGeneration = 12;
    snapshot.boundSystemAudioGeneration = 41;
    snapshot.currentSystemAudioGeneration = 42;
    snapshot.boundOwnershipToken = 91;
    snapshot.currentOwnershipToken = 92;
    snapshot.sessionActive = YES;
    snapshot.recoveryRequired = NO;
    snapshot.explicitResumeRequired = NO;
    snapshot.playing = YES;
    snapshot.routeClosureRecorded = YES;
    snapshot.inputRequired = YES;
    snapshot.preferredInputRequired = YES;
    snapshot.playoutGateClosedAndDrained = YES;
    snapshot.microphoneGateClosedAndDrained = YES;
    snapshot.boundCursorFingerprint =
        @"inputs{BuiltInMic:PRIVATE-INPUT-UID}outputs{Speaker:PRIVATE-OUTPUT-UID}";
    snapshot.boundPreparedRouteFingerprint =
        @"inputs{BuiltInMic:PRIVATE-INPUT-UID}outputs{Speaker:PRIVATE-OUTPUT-UID}";
    snapshot.boundOutputFingerprint = @"Speaker:PRIVATE-OUTPUT-UID";
    snapshot.boundTargetInputIdentifier = @"PRIVATE-INPUT-UID";
    snapshot.currentRouteFingerprint =
        @"inputs{BuiltInMic:PRIVATE-INPUT-UID}outputs{Speaker:PRIVATE-OUTPUT-UID}";
    snapshot.currentOutputFingerprint = @"Speaker:PRIVATE-OUTPUT-UID";
    snapshot.currentInputType = AVAudioSessionPortBuiltInMic;
    snapshot.currentInputIdentifier = @"PRIVATE-INPUT-UID";
    snapshot.preferredInputType = AVAudioSessionPortBuiltInMic;
    snapshot.preferredInputIdentifier = @"PRIVATE-INPUT-UID";
    snapshot.category = AVAudioSessionCategoryPlayAndRecord;
    snapshot.mode = AVAudioSessionModeDefault;
    snapshot.categoryOptions = ASIPhoneMicrophoneCategoryOptions();
    snapshot.sharingPolicy = AVAudioSessionRouteSharingPolicyDefault;
    snapshot.inputCount = 1;
    snapshot.outputCount = 1;
    snapshot.inputChannels = ASInputChannelCount;
    snapshot.outputChannels = ASOutputChannelCount;
    snapshot.failedPredicates = @[
        @"notificationSequence",
        @"configurationGeneration",
        @"systemAudioGeneration",
        @"ownershipToken",
    ];
    return ASRouteTransactionFailureSnapshotDescription(snapshot);
}

- (NSUInteger)configurationOperationCount {
    return [self.device debugConfigurationOperationCountForTesting];
}

- (NSString *)lastConfiguredCategory {
    return [self.device debugLastConfiguredCategoryForTesting];
}

- (NSString *)lastConfiguredMode {
    return [self.device debugLastConfiguredModeForTesting];
}

- (NSInteger)lastConfiguredRouteSharingPolicy {
    return [self.device debugLastConfiguredRouteSharingPolicyForTesting];
}

- (NSUInteger)lastConfiguredCategoryOptions {
    return [self.device debugLastConfiguredCategoryOptionsForTesting];
}

- (BOOL)lastConfiguredInputBusEnabled {
    return [self.device debugLastConfiguredInputBusEnabledForTesting];
}

- (BOOL)lastConfiguredOutputBusEnabled {
    return [self.device debugLastConfiguredOutputBusEnabledForTesting];
}

- (AudioStreamBasicDescription)lastConfiguredOutputStreamFormat {
    return [self.device debugLastConfiguredOutputStreamFormatForTesting];
}

- (NSUUID *)hostedCallPolicyIdentifier {
    return [self.device debugHostedCallPolicyIdentifierForTesting];
}

- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                status:(int32_t)status {
    ASPublishPlayoutCallback(
        &self.device->_realtime,
        frameCount,
        status,
        NULL,
        NULL
    );
}

- (void)queueRecoveryWithAuthorization:
    (ASIOSStereoPlayoutRecoveryAuthorization *)authorization {
    [self.device requestPlayoutRecoveryWithAuthorization:authorization];
}

- (void)queueHostedCallRecoveryWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization {
    [self.device requestHostedCallPlayoutRecoveryWithAuthorization:authorization];
}

- (BOOL)armStartupConnectedCallPlayoutWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization {
    return [self.device
        armStartupConnectedCallPlayoutWithAuthorization:authorization];
}

- (BOOL)debugStartPlayoutForTesting {
    return [self.device startPlayout];
}

- (void)debugMarkInterruptedFailClosedForTesting {
    [self.device debugMarkInterruptedFailClosedForTesting];
}

- (void)debugMarkInterruptionEndedFailClosedForTesting {
    [self.device debugMarkInterruptionEndedFailClosedForTesting];
}

- (void)debugMarkHealthyPlayoutForTesting {
    [self.device debugMarkHealthyPlayoutForTesting];
}

- (void)debugMarkRouteLossForTesting {
    [self.device debugMarkRouteLossForTesting];
}

- (void)debugAttemptFailureOverwriteForTesting {
    [self.device publishFailureCode:ASIOSStereoPlayoutFailureAudioUnitStop
                             status:-12345
                            message:@"A later teardown failure must not replace explicit-resume evidence."];
}

- (void)debugAdvanceSystemAudioGenerationForTesting {
    [self.device debugAdvanceSystemAudioGenerationForTesting];
}

- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available {
    [self.device debugSetOutputRouteAvailableForTesting:available];
}

- (void)debugSetCaptureRouteBuiltInMicrophoneForTesting:
    (BOOL)isBuiltIn {
    [self.device
        debugSetCaptureRouteBuiltInMicrophoneForTesting:isBuiltIn];
}

- (void)debugFailNextHostedCallActivationForTesting {
    [self.device debugFailNextHostedCallActivationForTesting];
}

- (BOOL)runNextQueuedOperation {
    dispatch_block_t operation = [self.delegate takeNextOperation];
    if (operation == nil) {
        return NO;
    }
    operation();
    return YES;
}

- (void)debugInstallMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *)authorization {
    [self.device debugInstallMicrophoneAuthorizationForTesting:authorization];
}

- (BOOL)setMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *)authorization {
    return [self.device setMicrophoneAuthorization:authorization];
}

- (BOOL)debugPublishCurrentMicrophoneAuthorizationForTesting {
    return [self.device debugPublishCurrentMicrophoneAuthorizationForTesting];
}

- (BOOL)debugBeginRealtimeAdmissionForTesting {
    return [self.device debugBeginRealtimeAdmissionForTesting];
}

- (void)debugEndRealtimeAdmissionForTesting {
    [self.device debugEndRealtimeAdmissionForTesting];
}

- (void)debugCloseAndFenceRealtimeGateForTesting {
    [self.device debugCloseAndFenceRealtimeGateForTesting];
}

- (void)waitForRealtimeGateClosureForTesting {
    [self.device waitForRealtimeGateClosureForTesting];
}

- (BOOL)debugTerminateForTesting {
    return [self.device debugTerminateForTesting];
}

@end

@implementation ASIOSRouteConfigurationChangeArbitrationTestHarness

- (BOOL)debugWaiterFirstResolvesForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *notification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionTimedOut;
    ASAwaitRouteConfigurationChangeDisposition(
        notification,
        observerIdentifier,
        0.25,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            callbackCount += 1;
            observed = result;
            dispatch_semaphore_signal(completed);
        }
    );
    ASDebugBeginRouteConfigurationChangeResolution(notification);
    ASDebugResolveRouteConfigurationChangeDisposition(
        notification,
        disposition
    );
    long waitResult = dispatch_semaphore_wait(
        completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    BOOL result = waitResult == 0
        && callbackCount == 1
        && observed == disposition;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (BOOL)debugNativeFirstResolvesForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *notification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    ASDebugBeginRouteConfigurationChangeResolution(notification);
    ASDebugResolveRouteConfigurationChangeDisposition(
        notification,
        disposition
    );
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionTimedOut;
    ASAwaitRouteConfigurationChangeDisposition(
        notification,
        observerIdentifier,
        0.25,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            callbackCount += 1;
            observed = result;
            dispatch_semaphore_signal(completed);
        }
    );
    long waitResult = dispatch_semaphore_wait(
        completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    BOOL result = waitResult == 0
        && callbackCount == 1
        && observed == disposition;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (BOOL)debugNativeFirstResolverReplacementPreservesDispositionForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *notification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    ASDebugBeginRouteConfigurationChangeResolution(notification);
    ASDebugResolveRouteConfigurationChangeDisposition(
        notification,
        disposition
    );
    ASDebugReplaceRouteConfigurationChangeResolver();

    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionTimedOut;
    ASAwaitRouteConfigurationChangeDisposition(
        notification,
        observerIdentifier,
        0.25,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            callbackCount += 1;
            observed = result;
            dispatch_semaphore_signal(completed);
        }
    );
    long waitResult = dispatch_semaphore_wait(
        completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    BOOL result = waitResult == 0
        && callbackCount == 1
        && observed == disposition;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (BOOL)debugExactNotificationIdentityRejectsStaleResolutionForTesting {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *retiredNotification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    NSNotification *replacementNotification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    ASDebugBeginRouteConfigurationChangeResolution(retiredNotification);
    ASDebugResolveRouteConfigurationChangeDisposition(
        retiredNotification,
        ASIOSRouteConfigurationChangeDispositionConsumed
    );
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionConsumed;
    ASAwaitRouteConfigurationChangeDisposition(
        replacementNotification,
        observerIdentifier,
        0.01,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            observed = result;
            dispatch_semaphore_signal(completed);
        }
    );
    long waitResult = dispatch_semaphore_wait(
        completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    BOOL result = waitResult == 0
        && observed == ASIOSRouteConfigurationChangeDispositionTimedOut;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (BOOL)debugTimeoutCompletesExactlyOnceForTesting {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *notification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    dispatch_semaphore_t firstCompletion = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionConsumed;
    ASAwaitRouteConfigurationChangeDisposition(
        notification,
        observerIdentifier,
        0.01,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            callbackCount += 1;
            observed = result;
            dispatch_semaphore_signal(firstCompletion);
        }
    );
    ASDebugBeginRouteConfigurationChangeResolution(notification);
    long firstWait = dispatch_semaphore_wait(
        firstCompletion,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );
    ASDebugResolveRouteConfigurationChangeDisposition(
        notification,
        ASIOSRouteConfigurationChangeDispositionGeneric
    );
    // All production dispositions use this serial delivery queue. Because
    // debug resolution above is synchronous on the arbitration queue, this
    // barrier deterministically joins every callback it could have submitted.
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    BOOL result = firstWait == 0
        && callbackCount == 1
        && observed == ASIOSRouteConfigurationChangeDispositionTimedOut;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (BOOL)debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting {
    uint64_t observerIdentifier =
        ASAllocateRouteConfigurationChangeObserverIdentifier();
    ASActivateRouteConfigurationChangeObserverIdentifier(observerIdentifier);
    NSNotification *notification = [NSNotification
        notificationWithName:@"ASDebugRouteConfigurationChange"
                      object:nil];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    __block ASIOSRouteConfigurationChangeDisposition observed =
        ASIOSRouteConfigurationChangeDispositionConsumed;
    ASAwaitRouteConfigurationChangeDisposition(
        notification,
        observerIdentifier,
        0.25,
        ^(ASIOSRouteConfigurationChangeDisposition result) {
            callbackCount += 1;
            observed = result;
            dispatch_semaphore_signal(completed);
        }
    );
    BOOL timeoutCompleted =
        ASDebugTimeoutRouteConfigurationChangeDisposition(
            notification,
            observerIdentifier
        );
    long firstWait = dispatch_semaphore_wait(
        completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)
    );

    ASDebugBeginRouteConfigurationChangeResolution(notification);
    ASDebugResolveRouteConfigurationChangeDisposition(
        notification,
        ASIOSRouteConfigurationChangeDispositionGeneric
    );
    dispatch_sync(
        ASRouteConfigurationChangeDispositionDeliveryQueue(),
        ^{}
    );
    NSUInteger recordCount =
        ASDebugRouteConfigurationChangeArbitrationRecordCount();
    BOOL result = timeoutCompleted
        && firstWait == 0
        && callbackCount == 1
        && observed == ASIOSRouteConfigurationChangeDispositionTimedOut
        && recordCount == 0;
    ASInvalidateRouteConfigurationChangeObserverIdentifier(
        observerIdentifier
    );
    return result;
}

- (NSUInteger)debugArbitrationRecordCountForTesting {
    return ASDebugRouteConfigurationChangeArbitrationRecordCount();
}

@end
#endif

/// Realtime boundary: no allocation, lock, log, conversion, or intermediate PCM queue.
static OSStatus ASRemoteIORender(
    void *context,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32 outputBusNumber,
    UInt32 frameCount,
    AudioBufferList *outputData
) {
    // The Audio Unit holds `self` through the callback refCon until stop/dispose completes.
    // Borrow it and invoke the copied ivar directly so ARC emits no retain/release on this path.
    ASIOSStereoPlayoutAudioDevice * __unsafe_unretained device =
        (__bridge ASIOSStereoPlayoutAudioDevice *)context;
    if (device == nil) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return kAudio_ParamError;
    }
    ASRealtimeGate *playoutGate = &device->_realtimePlayoutDeviceGate;
    if (!ASBeginDeviceRealtimeAdmission(playoutGate)) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        return noErr;
    }
    if (!atomic_load_explicit(
            &device->_lifecycle.playing,
            memory_order_acquire
        )) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        ASEndDeviceRealtimeAdmission(playoutGate);
        return noErr;
    }
    if (device->_playoutBlock == nil || outputData == NULL) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        ASBeginRealtimePublication(&device->_realtime);
        ASPublishPlayoutCallback(
            &device->_realtime,
            frameCount,
            kAudio_ParamError
            #if DEBUG
            , NULL, NULL
            #endif
        );
        ASEndRealtimePublication(&device->_realtime);
        ASEndDeviceRealtimeAdmission(playoutGate);
        return kAudio_ParamError;
    }

    // WebRTC's FineAudioBuffer accepts RemoteIO's route-dependent callback sizes and writes
    // signed-16-bit interleaved L/R samples directly into RemoteIO's provided buffers.
    OSStatus status = device->_playoutBlock(
        actionFlags,
        timestamp,
        outputBusNumber,
        frameCount,
        outputData
    );
    ASBeginRealtimePublication(&device->_realtime);
    if (status != noErr) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
    } else {
        // RemoteIO normally supplies the monotonic host timestamp. `mach_absolute_time` is the
        // allocation-free fallback; its timebase was cached before playout reached this callback.
        // Recording only successful callbacks avoids treating error publication as output proof.
        uint64_t hostTime = timestamp != NULL
            && (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0
                ? timestamp->mHostTime
                : mach_absolute_time();
        ASRecordSuccessfulCallbackTime(
            &device->_realtime,
            hostTime,
            device->_realtime.hostTimebaseNumerator,
            device->_realtime.hostTimebaseDenominator
        );
        ASAnalyzeRenderedPCM(
            &device->_realtime,
            outputData,
            frameCount,
            actionFlags == NULL ? 0 : *actionFlags
        );
    }
    ASPublishPlayoutCallback(
        &device->_realtime,
        frameCount,
        status
        #if DEBUG
        , NULL, NULL
        #endif
    );
    ASEndRealtimePublication(&device->_realtime);
    ASEndDeviceRealtimeAdmission(playoutGate);
    return status;
}

/// Realtime microphone boundary: preallocated mono PCM, one AudioUnitRender,
/// and one synchronous deliverRecordedData invocation.
static OSStatus ASRemoteIOInput(
    void *context,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    UInt32 inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *unusedData
) {
    (void)unusedData;
    ASIOSStereoPlayoutAudioDevice * __unsafe_unretained device =
        (__bridge ASIOSStereoPlayoutAudioDevice *)context;
    if (device == nil) {
        return noErr;
    }

    if (!atomic_load_explicit(
            &device->_lifecycle.playing,
            memory_order_acquire
        )) {
        return noErr;
    }

    ASRealtimeGate *deviceGate = &device->_realtimeMicrophoneDeviceGate;
    if (!ASBeginDeviceRealtimeAdmission(deviceGate)) {
        return noErr;
    }

    unsigned long authorizationGateBits = atomic_load_explicit(
        &device->_realtimeMicrophoneAuthorizationGate,
        memory_order_acquire
    );
    ASRealtimeGate *authorizationGate =
        (ASRealtimeGate *)(uintptr_t)authorizationGateBits;
    if (authorizationGate == NULL
        || !ASBeginAuthorizationRealtimeAdmission(authorizationGate)) {
        ASEndDeviceRealtimeAdmission(deviceGate);
        return noErr;
    }

    if (ASRealtimeGateIsClosed(deviceGate)
        || ASRealtimeGateIsClosed(authorizationGate)) {
        ASEndAuthorizationRealtimeAdmission(authorizationGate);
        ASEndDeviceRealtimeAdmission(deviceGate);
        return noErr;
    }

    uint64_t recordingGeneration = atomic_load_explicit(
        &device->_realtimeMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    uint64_t approvedRecordingGeneration = atomic_load_explicit(
        &device->_realtimeApprovedMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    if (recordingGeneration == 0
        || approvedRecordingGeneration != recordingGeneration) {
        ASEndAuthorizationRealtimeAdmission(authorizationGate);
        ASEndDeviceRealtimeAdmission(deviceGate);
        return noErr;
    }

    atomic_fetch_add_explicit(
        &device->_realtime.microphoneRealtimeAdmissionCount,
        1,
        memory_order_relaxed
    );

    BOOL recording = device->_recording;
    AudioComponentInstance audioUnit = device->_audioUnit;
    LKRTCAudioDeviceDeliverRecordedDataBlock __unsafe_unretained recordedDataBlock =
        device->_recordedDataBlock;
    int16_t *recordingSamples = device->_recordingSamples;
    UInt32 recordingSampleCapacity = device->_recordingSampleCapacity;

    OSStatus status = noErr;
    if (recording
        && audioUnit != NULL
        && recordedDataBlock != nil
        && recordingSamples != NULL
        && frameCount > 0
        && frameCount <= recordingSampleCapacity) {
        AudioBufferList inputData = {0};
        inputData.mNumberBuffers = 1;
        inputData.mBuffers[0].mNumberChannels = ASInputChannelCount;
        inputData.mBuffers[0].mDataByteSize =
            frameCount * ASInputChannelCount * sizeof(int16_t);
        inputData.mBuffers[0].mData = recordingSamples;

        status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            inputBusNumber,
            frameCount,
            &inputData
        );
        if (status == noErr) {
            atomic_fetch_add_explicit(
                &device->_realtime.microphoneDeliveryCallbackCount,
                1,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &device->_realtime.microphoneDeliveredFrameCount,
                frameCount,
                memory_order_relaxed
            );
            status = recordedDataBlock(
                actionFlags,
                timestamp,
                inputBusNumber,
                frameCount,
                &inputData,
                NULL,
                NULL
            );
        }
    }

    ASEndAuthorizationRealtimeAdmission(authorizationGate);
    ASEndDeviceRealtimeAdmission(deviceGate);
    return status;
}

@implementation ASIOSStereoPlayoutAudioDevice

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    ASInitializeRealtimeDiagnostics(&_realtime);
    ASInitializeRealtimeGateClosed(&_realtimePlayoutDeviceGate);
    ASInitializeRealtimeGateClosed(&_realtimeMicrophoneDeviceGate);
    atomic_init(&_realtimeMicrophoneAuthorizationGate, 0);
    atomic_init(&_realtimeMicrophoneRecordingGeneration, 0);
    atomic_init(&_realtimeApprovedMicrophoneRecordingGeneration, 0);
    atomic_init(&_captureRouteProofGeneration, 0);
    atomic_init(&_microphoneApprovalConsumedGeneration, 0);
    atomic_init(&_systemAudioGeneration, 0);
    atomic_init(&_activeAudioConfigurationGeneration, 0);
    _microphoneRecordingGenerationCounter = 0;
    _captureRouteProofGenerationCounter = 0;
    _audioConfigurationGenerationCounter = 0;
    _expectedMicrophoneRouteChangeLock = OS_UNFAIR_LOCK_INIT;
    _expectedMicrophoneRouteChangeEvidenceQueue = dispatch_queue_create(
        "com.elamin.opensteamer.ios-audio.route-evidence",
        DISPATCH_QUEUE_SERIAL
    );
    _routeChangeNotificationSequence = 0;
    _nonCategoryRouteChangeNotificationSequence = 0;
    _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 0;
    _expectedMicrophoneRouteChangeTransactionIdentifier = 0;
    _expectedMicrophoneRouteChangeMutationSequence = 0;
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStateNone;
    _expectedMicrophoneRouteChangeTransactionIdentifier = 0;
    _expectedMicrophoneRouteChangeConfigurationGeneration = 0;
    _expectedMicrophoneRouteChangeOwnershipToken = 0;
    _expectedMicrophoneRouteChangeSystemAudioGeneration = 0;
    _expectedMicrophoneRouteChangeObserverSequenceBaseline = 0;
    _expectedMicrophoneRouteChangeDeadlineNanoseconds = 0;
    _expectedMicrophoneRouteChangeStartSettlement =
        (ASRemoteIOStartSettlement){0};
    _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence = NO;
    _expectedMicrophoneRouteChangeTransitionCursorFingerprint = nil;
    _expectedMicrophoneRouteChangeConvergedRouteFingerprint = nil;
    _expectedMicrophoneRouteChangeOutputFingerprint = nil;
    _expectedMicrophoneRouteChangeTargetInputIdentifier = nil;
    _expectedMicrophoneRouteChangeInputRequired = NO;
    _expectedMicrophoneRouteChangeRequiresPreferredInput = NO;
    _expectedMicrophoneRouteChangeSemaphore = nil;
    _expectedMicrophoneRouteChangeRejectionSnapshot = nil;
    _audioUnitRunning = NO;
    _routeConfigurationChangeResolverEpoch = 0;
#if DEBUG
    _debugRealtimeAdmissionLock = OS_UNFAIR_LOCK_INIT;
    _debugAdmittedDeviceGate = NULL;
    _debugAdmittedAuthorizationGate = NULL;
    _debugDeviceGateClosureSemaphore = dispatch_semaphore_create(0);
    atomic_init(&_debugDeviceGateClosureSignaled, false);
    _debugRecoveryHarnessMode = NO;
    _debugHealthyPlayoutForTesting = NO;
    _debugHasOutputRouteOverride = NO;
    _debugHasOutputRoute = NO;
    _debugCaptureRouteIsBuiltInMicrophone = NO;
    _debugFailNextHostedCallActivation = NO;
    _debugOwnsSessionActivation = NO;
    _debugConfigurationOperationCount = 0;
    _debugHasRecordedAudioPolicyConfiguration = NO;
    _debugLastConfiguredCategory = nil;
    _debugLastConfiguredMode = nil;
    _debugLastConfiguredRouteSharingPolicy = AVAudioSessionRouteSharingPolicyDefault;
    _debugLastConfiguredCategoryOptions = 0;
    _debugLastConfiguredInputBusEnabled = NO;
    _debugLastConfiguredOutputBusEnabled = NO;
    _debugLastConfiguredOutputStreamFormat = (AudioStreamBasicDescription){0};
#endif
    atomic_init(&_lifecycle.initialized, false);
    atomic_init(&_lifecycle.playoutInitialized, false);
    atomic_init(&_lifecycle.playing, false);
    atomic_init(&_lifecycle.sessionActive, false);
    atomic_init(&_lifecycle.remoteIOCreated, false);
    atomic_init(&_lifecycle.inputBusEnabled, false);
    atomic_init(&_lifecycle.outputBusEnabled, false);
    atomic_init(&_lifecycle.recoveryRequired, false);
    atomic_init(&_lifecycle.explicitResumeRequired, false);
    atomic_init(&_lifecycle.hostedCallMode, false);
    atomic_init(&_lifecycle.hostedCallAuthorizationValid, false);
    atomic_init(&_lifecycle.hostedCallRecoveryPending, false);
    atomic_init(
        &_lifecycle.hostedCallOrigin,
        ASIOSHostedCallPlayoutOriginUnspecified
    );
    atomic_init(&_lifecycle.hostedCallAuthorizationGeneration, 0);
    atomic_init(&_lifecycle.audioUnitSubType, 0);
    atomic_init(&_lifecycle.failureCode, ASIOSStereoPlayoutFailureNone);
    atomic_init(&_lifecycle.lastLifecycleStatus, noErr);
    _streamFormat = (AudioStreamBasicDescription) {
        .mSampleRate = ASSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = ASOutputChannelCount * sizeof(int16_t),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = ASOutputChannelCount * sizeof(int16_t),
        .mChannelsPerFrame = ASOutputChannelCount,
        .mBitsPerChannel = 16,
    };
    _inputStreamFormat = (AudioStreamBasicDescription) {
        .mSampleRate = ASSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = sizeof(int16_t),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(int16_t),
        .mChannelsPerFrame = ASInputChannelCount,
        .mBitsPerChannel = 16,
    };
    return self;
}

- (void)dealloc {
    [self terminateDevice];
}

- (double)deviceInputSampleRate { return ASSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return ASIOBufferDuration; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return 0; }
- (double)deviceOutputSampleRate { return ASSampleRate; }
- (NSTimeInterval)outputIOBufferDuration {
    // A preferred duration is not a hardware guarantee. Once this device owns an active session,
    // report the actual route value required by LKRTCAudioDevice/FineAudioBuffer.
    if (_sessionActive && [self ownsCurrentSessionActivation]) {
        NSTimeInterval duration = [self currentAudioSession].IOBufferDuration;
        if (duration > 0) {
            return duration;
        }
    }
    return ASIOBufferDuration;
}
- (NSInteger)outputNumberOfChannels { return ASOutputChannelCount; }
- (NSTimeInterval)outputLatency {
    return [self currentAudioSession].outputLatency;
}
- (BOOL)isInitialized { return _initialized; }
- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)isRecordingInitialized { return _initialized; }
- (BOOL)isRecording { return _wantsRecording; }

- (BOOL)initializeWithDelegate:(id<LKRTCAudioDeviceDelegate>)delegate {
    if (_initialized || delegate == nil) {
        return NO;
    }
    [self closeAndFenceRealtimePlayoutResources];
    [self closeAndFenceRealtimeMicrophoneResources];
    __attribute__((objc_precise_lifetime))
    ASIOSMicrophoneAuthorization *retiringAuthorization =
        _microphoneAuthorization;
    _microphoneAuthorization = nil;
    [retiringAuthorization revoke];
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];

    self.delegate = delegate;
    _playoutBlock = [delegate.getPlayoutData copy];
    _recordedDataBlock = [delegate.deliverRecordedData copy];
    if (_playoutBlock == nil || _recordedDataBlock == nil) {
        _playoutBlock = nil;
        _recordedDataBlock = nil;
        self.delegate = nil;
        return NO;
    }
    _wantsPlayout = NO;
    _wantsRecording = NO;
    _recording = NO;
    _audioUnitRunning = NO;
    _interrupted = NO;
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    _isRebuilding = NO;
#if DEBUG
    _debugHealthyPlayoutForTesting = NO;
    _debugOwnsSessionActivation = NO;
#endif
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    [self clearLifecycleFailure];
    _initialized = YES;
    atomic_store_explicit(
        &_lifecycle.initialized,
        true,
        memory_order_release
    );
#if DEBUG
    if (!_debugRecoveryHarnessMode) {
        _routeConfigurationChangeResolverEpoch =
            ASRegisterRouteConfigurationChangeResolver(
                (uintptr_t)(__bridge const void *)self
            );
        [self subscribeToSystemAudioNotifications];
    }
#else
    _routeConfigurationChangeResolverEpoch =
        ASRegisterRouteConfigurationChangeResolver(
            (uintptr_t)(__bridge const void *)self
        );
    [self subscribeToSystemAudioNotifications];
#endif
    return YES;
}

- (BOOL)terminateDevice {
    _wantsPlayout = NO;
    _wantsRecording = NO;
    // Publish retirement before removing the observer or beginning native
    // teardown. An already-running NotificationCenter callback can therefore
    // only resolve Uninitialized while this device still owns the resolver
    // epoch; every later callback is fenced to generic timeout recovery.
    _initialized = NO;
    atomic_store_explicit(
        &_lifecycle.initialized,
        false,
        memory_order_release
    );
    uint64_t retiringRouteResolverEpoch =
        _routeConfigurationChangeResolverEpoch;
    _routeConfigurationChangeResolverEpoch = 0;
    ASRetireRouteConfigurationChangeResolver(
        (uintptr_t)(__bridge const void *)self,
        retiringRouteResolverEpoch
    );
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    [self unsubscribeFromSystemAudioNotifications];
    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];

    __attribute__((objc_precise_lifetime))
    ASIOSMicrophoneAuthorization *retiringAuthorization =
        _microphoneAuthorization;
    _microphoneAuthorization = nil;
    [retiringAuthorization revoke];

    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    if (teardownStatus != noErr) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureAudioUnitStop
                         status:(int32_t)teardownStatus
                        message:[NSString stringWithFormat:
                            @"RemoteIO teardown failed during device termination (%d).",
                            (int)teardownStatus]];
    } else if (!deactivated) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureSessionDeactivation
                         status:(int32_t)deactivationError.code
                        message:[NSString stringWithFormat:
                            @"Audio-session deactivation failed during device termination: %@",
                            deactivationError.localizedDescription ?: @"unknown error"]];
    }
    _playoutInitialized = NO;
    _interrupted = NO;
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    _isRebuilding = NO;
    _recording = NO;
    atomic_store_explicit(&_lifecycle.playoutInitialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    // The microphone resource gate was closed and drained before native teardown, so no input
    // callback can still be using the copied delivery block when it is cleared here.
    _playoutBlock = nil;
    _recordedDataBlock = nil;
    self.delegate = nil;
    return teardownStatus == noErr && deactivated;
}

- (BOOL)initializePlayout {
    ASIOSHostedCallPlayoutAuthorization *authorization =
        _hostedCallAuthorization;
    BOOL protectsStartupPolicy = authorization != nil
        && authorization.origin
            == ASIOSHostedCallPlayoutOriginStartupConnectedCall;
    if (!protectsStartupPolicy) {
        return [self initializePlayoutForCurrentPolicy];
    }

    __block BOOL initialized = NO;
    ASIOSHostedCallPlayoutAuthorization *previousInProgress =
        _hostedCallRecoveryInProgressAuthorization;
    _hostedCallRecoveryInProgressAuthorization = authorization;
    BOOL authorized = [authorization performWhileValid:^{
        uint64_t currentGeneration = atomic_load_explicit(
            &self->_systemAudioGeneration,
            memory_order_acquire
        );
        BOOL exactStartupPolicy =
            !authorization.isRecoveryPending
            && currentGeneration != 0
            && self->_hostedCallAuthorization == authorization
            && self->_hostedCallPolicyIdentifier != nil
            && [self->_hostedCallPolicyIdentifier
                isEqual:authorization.policyIdentifier]
            && self->_hostedCallAuthorizationGeneration == currentGeneration
            && authorization.systemAudioGeneration == currentGeneration
            && [self hostedCallModeIsAuthorized];
        if (exactStartupPolicy) {
            initialized = [self initializePlayoutForCurrentPolicy];
        }
    }];
    _hostedCallRecoveryInProgressAuthorization = previousInProgress;
    if (!authorized || !initialized) {
        _recoveryRequired = YES;
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            true,
            memory_order_relaxed
        );
    }
    return authorized && initialized;
}

- (BOOL)initializePlayoutForCurrentPolicy {
    BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
    BOOL hasHostedCallOwnership =
        _hostedCallAuthorization != nil
        || _hostedCallPolicyIdentifier != nil
        || _hostedCallAuthorizationGeneration != 0;
    if (!_initialized
        || (hasHostedCallOwnership && !hostedCallMode)
        || (_interrupted && !hostedCallMode)
        || _recoveryRequired
        || _explicitResumeRequired) {
        return NO;
    }
    if (_playoutInitialized && (_audioUnit != NULL
#if DEBUG
        || (_debugRecoveryHarnessMode
            && _sessionActive
            && _debugOwnsSessionActivation
            && _outputBusEnabled)
#endif
    )) {
        return YES;
    }

    BOOL configured = [self configureSessionAndCreateRemoteIO];
#if DEBUG
    if (configured && _debugRecoveryHarnessMode) {
        BOOL microphoneEnabled = [self microphoneShouldBeActive];
        ASAudioPolicyConfiguration configuration =
            ASMakeAudioPolicyConfiguration(
                hostedCallMode,
                microphoneEnabled,
                _streamFormat
            );
        if (![self sessionMatchesCurrentPolicy:nil]
            || (hostedCallMode && ![self hasOutputRouteForSession:nil])) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionConfiguration
                                   status:kAudio_ParamError
                                  message:@"The deterministic first playout initialization no longer matches the selected production policy."];
            return NO;
        }

        _debugHealthyPlayoutForTesting = !hostedCallMode;
        _debugOwnsSessionActivation = YES;
        _sessionActive = YES;
        _playoutInitialized = YES;
        _playing = NO;
        _inputBusEnabled = configuration.inputBusEnabled;
        _outputBusEnabled = configuration.outputBusEnabled;
        _recording = configuration.inputBusEnabled;
        _audioUnitSubType = 0;
        _recoveryRequired = NO;
        _explicitResumeRequired = NO;
        atomic_store_explicit(
            &_lifecycle.sessionActive,
            true,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.playoutInitialized,
            true,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.playing,
            false,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.remoteIOCreated,
            false,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.inputBusEnabled,
            configuration.inputBusEnabled,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.outputBusEnabled,
            configuration.outputBusEnabled,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.audioUnitSubType,
            0,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            false,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.explicitResumeRequired,
            false,
            memory_order_relaxed
        );
        [self clearLifecycleFailure];
    }
#endif
    return configured;
}

- (BOOL)startPlayout {
    ASIOSHostedCallPlayoutAuthorization *authorization =
        _hostedCallAuthorization;
    BOOL protectsStartupPolicy = authorization != nil
        && authorization.origin
            == ASIOSHostedCallPlayoutOriginStartupConnectedCall;
    if (!protectsStartupPolicy) {
        return [self startPlayoutForCurrentPolicy];
    }

    __block BOOL started = NO;
    ASIOSHostedCallPlayoutAuthorization *previousInProgress =
        _hostedCallRecoveryInProgressAuthorization;
    _hostedCallRecoveryInProgressAuthorization = authorization;
    BOOL authorized = [authorization performWhileValid:^{
        uint64_t currentGeneration = atomic_load_explicit(
            &self->_systemAudioGeneration,
            memory_order_acquire
        );
        BOOL exactStartupPolicy =
            !authorization.isRecoveryPending
            && currentGeneration != 0
            && self->_hostedCallAuthorization == authorization
            && self->_hostedCallPolicyIdentifier != nil
            && [self->_hostedCallPolicyIdentifier
                isEqual:authorization.policyIdentifier]
            && self->_hostedCallAuthorizationGeneration == currentGeneration
            && authorization.systemAudioGeneration == currentGeneration
            && [self hostedCallModeIsAuthorized];
        if (exactStartupPolicy) {
            started = [self startPlayoutForCurrentPolicy];
        }
    }];
    _hostedCallRecoveryInProgressAuthorization = previousInProgress;
    if (!authorized || !started) {
        _recoveryRequired = YES;
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            true,
            memory_order_relaxed
        );
    }
    return authorized && started;
}

- (BOOL)startPlayoutForCurrentPolicy {
    _wantsPlayout = YES;
    BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
    BOOL hasHostedCallOwnership =
        _hostedCallAuthorization != nil
        || _hostedCallPolicyIdentifier != nil
        || _hostedCallAuthorizationGeneration != 0;
    if ((hasHostedCallOwnership && !hostedCallMode)
        || (_interrupted && !hostedCallMode)
        || _recoveryRequired
        || _explicitResumeRequired) {
        if (atomic_load_explicit(&_lifecycle.failureCode, memory_order_relaxed)
            == ASIOSStereoPlayoutFailureNone) {
            [self publishFailureCode:ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                             status:noErr
                            message:@"Playout is fail-closed until application-authorized recovery."];
        }
        return NO;
    }
    if (![self initializePlayoutForCurrentPolicy]) {
        return NO;
    }
#if DEBUG
    if (_debugRecoveryHarnessMode && _audioUnit == NULL) {
        if (!_playoutInitialized
            || !_sessionActive
            || !_debugOwnsSessionActivation
            || !_outputBusEnabled
            || ![self sessionMatchesCurrentPolicy:nil]
            || (hostedCallMode && ![self hasOutputRouteForSession:nil])) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionConfiguration
                                   status:kAudio_ParamError
                                  message:@"The deterministic first StartPlayout boundary did not retain the selected production policy."];
            return NO;
        }
        _playing = YES;
        atomic_store_explicit(
            &_lifecycle.playing,
            true,
            memory_order_relaxed
        );
        return YES;
    }
#endif
    if (_audioUnit == NULL) {
        return NO;
    }
    if (_playing) {
        AVAudioSession *session = [self currentAudioSession];
        if (![self sessionMatchesCurrentPolicy:session]
            || (hostedCallMode && ![self hasOutputRouteForSession:session])) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureUnexpectedCategoryChange
                                   status:kAudio_ParamError
                                  message:@"The active audio session no longer matches the current playout policy."];
            return NO;
        }

        return YES;
    }
    AVAudioSession *session = [self currentAudioSession];
    __attribute__((cleanup(ASReleaseUnfairLockScope)))
    ASUnfairLockScope startConfigurationScope = {
        .lock = NULL,
    };
    os_unfair_lock_lock(&ASSessionConfigurationLock);
    startConfigurationScope.lock = &ASSessionConfigurationLock;
    uint64_t hostedRouteSequence = 0;
    if (!hostedCallMode) {
        if (![self
            beginExpectedMicrophoneRouteChangeAudioUnitStartForSession:
                session]) {
            ASExpectedMicrophoneRouteChangeState state =
                [self expectedMicrophoneRouteChangeState];
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseBeginStart
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"RemoteIO start was blocked because the expected route transaction was not prepared (phase=%lu). %@ %@",
                                      (unsigned long)state,
                                      ASAudioSessionDiagnosticDescription(session),
                                      routeSnapshot]];
            return NO;
        }
    } else {
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        hostedRouteSequence =
            _nonCategoryRouteChangeNotificationSequence;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    }

    atomic_store_explicit(
        &_lifecycle.playing,
        false,
        memory_order_release
    );
    OSStatus status = AudioOutputUnitStart(_audioUnit);
    if (status != noErr) {
        NSString *message = nil;
        if (hostedCallMode) {
            message = [NSString stringWithFormat:
                @"RemoteIO start failed (%d).",
                (int)status];
        } else {
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseNativeStart
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            message = [NSString stringWithFormat:
                @"RemoteIO start failed (%d). %@",
                (int)status,
                routeSnapshot];
        }
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureAudioUnitStart
                               status:(int32_t)status
                              message:message];
        return NO;
    }
    _audioUnitRunning = YES;
    if (!hostedCallMode) {
        if (![self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted]) {
            ASExpectedMicrophoneRouteChangeState state =
                [self expectedMicrophoneRouteChangeState];
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseMarkStartCompleted
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"RemoteIO started, but its route transaction could not record the native start-completion boundary (phase=%lu); callbacks remained gated. %@ %@",
                                      (unsigned long)state,
                                      ASAudioSessionDiagnosticDescription(session),
                                      routeSnapshot]];
            return NO;
        }
        if (![self
            commitExpectedMicrophoneRouteChangeAfterAudioUnitStartForSession:
                session]) {
            ASExpectedMicrophoneRouteChangeState state =
                [self expectedMicrophoneRouteChangeState];
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseCommit
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"RemoteIO started, but its expected route transaction did not converge (phase=%lu); callbacks remained gated. %@ %@",
                                      (unsigned long)state,
                                      ASAudioSessionDiagnosticDescription(session),
                                      routeSnapshot]];
            return NO;
        }
        if (![self publishCommittedExpectedMicrophoneRouteChangePlayout]) {
            ASExpectedMicrophoneRouteChangeState state =
                [self expectedMicrophoneRouteChangeState];
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhasePublish
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"RemoteIO route transaction committed, but playout publication was blocked (phase=%lu); callbacks remained gated. %@ %@",
                                      (unsigned long)state,
                                      ASAudioSessionDiagnosticDescription(session),
                                      routeSnapshot]];
            return NO;
        }
    } else {
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL hostedPublicationIsSafe =
            _nonCategoryRouteChangeNotificationSequence
                == hostedRouteSequence
            && !atomic_load_explicit(
                &_lifecycle.recoveryRequired,
                memory_order_acquire
            )
            && !atomic_load_explicit(
                &_lifecycle.explicitResumeRequired,
                memory_order_acquire
            )
            && ASRealtimeGateIsClosedAndDrained(
                &_realtimePlayoutDeviceGate
            );
        if (hostedPublicationIsSafe) {
            _playing = YES;
            atomic_store_explicit(
                &_lifecycle.playing,
                true,
                memory_order_release
            );
            ASResetClosedRealtimeGate(&_realtimePlayoutDeviceGate);
        }
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!hostedPublicationIsSafe) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:@"Hosted-call RemoteIO start could not publish playout because its route sequence or callback gate changed during native start."];
            return NO;
        }
    }
    return YES;
}

- (BOOL)stopPlayout {
    _wantsPlayout = NO;
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    if (teardownStatus != noErr) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureAudioUnitStop
                         status:(int32_t)teardownStatus
                        message:[NSString stringWithFormat:
                            @"RemoteIO stop/teardown failed (%d).",
                            (int)teardownStatus]];
        return NO;
    }
    if (!deactivated) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureSessionDeactivation
                         status:(int32_t)deactivationError.code
                        message:[NSString stringWithFormat:
                            @"Audio-session deactivation failed after stopping playout: %@",
                            deactivationError.localizedDescription ?: @"unknown error"]];
        return NO;
    }
    return YES;
}

- (BOOL)initializeRecording {
    return _initialized;
}

- (BOOL)startRecording {
    if (!_initialized) {
        return NO;
    }

    if ([self hostedCallModeIsAuthorized]) {
        atomic_fetch_add_explicit(
            &_realtime.recordingRequestCount,
            1,
            memory_order_relaxed
        );
        [self retireMicrophoneAuthorizationForHostedCall];
        if (_inputBusEnabled) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneBusDisable
                                   status:kAudio_ParamError
                                  message:@"Hosted-call playout rejected an active microphone bus."];
        }
        return NO;
    }

    _wantsRecording = YES;
    ASIOSMicrophoneAuthorization *authorization = _microphoneAuthorization;
    BOOL authorizationValid = ASMicrophoneAuthorizationIsValid(authorization);
    if (_inputBusEnabled && !authorizationValid) {
        [self closeAndFenceRealtimeMicrophoneResources];
        return NO;
    }

    if (authorizationValid && _wantsPlayout && !_inputBusEnabled) {
        return [self rebuildForCurrentPolicy];
    }

    if (authorizationValid && _inputBusEnabled && _playing) {
        return YES;
    }

    return YES;
}

- (BOOL)stopRecording {
    _wantsRecording = NO;
    __attribute__((objc_precise_lifetime))
    ASIOSMicrophoneAuthorization *authorization = _microphoneAuthorization;
    _microphoneAuthorization = nil;
    [authorization revoke];
    [self clearCurrentMicrophoneRecordingGeneration];
    [self closeAndFenceRealtimeMicrophoneResources];
    if (_inputBusEnabled) {
        return [self rebuildForCurrentPolicy];
    }
    _recording = NO;
    return YES;
}

- (uint64_t)stageMicrophoneAuthorization:
    (ASIOSMicrophoneAuthorization *)authorization {
    if (authorization == nil) {
        return 0;
    }

    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        [authorization revoke];
        return 0;
    }

    __block uint64_t stagedGeneration = 0;
    [delegate dispatchSync:^{
        if (!self->_initialized || !authorization.isValid) {
            [authorization revoke];
            return;
        }

        if ([self hostedCallModeIsAuthorized]) {
            atomic_fetch_add_explicit(
                &self->_realtime.recordingRequestCount,
                1,
                memory_order_relaxed
            );
            [authorization revoke];
            [self retireMicrophoneAuthorizationForHostedCall];
            if (self->_inputBusEnabled) {
                [self failAndRollbackWithCode:
                    ASIOSStereoPlayoutFailureMicrophoneBusDisable
                                       status:kAudio_ParamError
                                      message:@"Hosted-call playout rejected a staged microphone-enable request."];
            }
            return;
        }

        [self closeAndFenceRealtimeMicrophoneResources];
        [self clearCurrentMicrophoneRecordingGeneration];
        [authorization clearMicrophoneRecordingGeneration];

        __block ASIOSMicrophoneAuthorization *displacedAuthorization = nil;
        BOOL installed = [authorization performWhileValid:^{
            displacedAuthorization = self->_microphoneAuthorization;
            self->_microphoneAuthorization = authorization;
            self->_wantsRecording = YES;
        }];
        if (!installed) {
            [authorization revoke];
            return;
        }

        __attribute__((objc_precise_lifetime))
        ASIOSMicrophoneAuthorization *retiringAuthorization =
            displacedAuthorization;
        if (retiringAuthorization != authorization) {
            [retiringAuthorization revoke];
        }

        BOOL allowDebugTopology = NO;
#if DEBUG
        allowDebugTopology = self->_debugRecoveryHarnessMode;
#endif
        BOOL topologyStaged =
            [self microphoneTopologyIsStagedAllowingDebugOverride:
                allowDebugTopology];
        if (!topologyStaged
            && self->_wantsPlayout
            && !self->_interrupted
            && !self->_recoveryRequired
            && !self->_explicitResumeRequired) {
            topologyStaged = [self rebuildForCurrentPolicy]
                && [self microphoneTopologyIsStagedAllowingDebugOverride:
                    allowDebugTopology];
        }

        if (topologyStaged
            && self->_microphoneAuthorization == authorization
            && authorization.isValid) {
            uint64_t generation =
                [self installNextMicrophoneRecordingGeneration];
            if ([authorization
                    bindMicrophoneRecordingGeneration:generation]) {
                stagedGeneration = generation;
            }
        }

        if (stagedGeneration == 0
            && self->_microphoneAuthorization == authorization) {
            [self closeAndFenceRealtimeMicrophoneResources];
            [self clearCurrentMicrophoneRecordingGeneration];
            self->_microphoneAuthorization = nil;
            self->_wantsRecording = NO;
            self->_recording = NO;
            [authorization revoke];
        }
    }];
    return stagedGeneration;
}

- (BOOL)approveStagedMicrophoneAuthorization:
            (ASIOSMicrophoneAuthorization *)authorization
                           recordingGeneration:(uint64_t)recordingGeneration {
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return NO;
    }

    __block BOOL approved = NO;
    [delegate dispatchSync:^{
        if (authorization == nil
            || recordingGeneration == 0
            || authorization.microphoneRecordingGeneration
                != recordingGeneration) {
            [self closeAndFenceRealtimeMicrophoneResources];
            return;
        }
        approved = [self
            publishFinalLiveMicrophoneResourcesWithAuthorization:authorization
                                          debugTopologyOverride:NO];
    }];
    return approved;
}

- (BOOL)setMicrophoneAuthorization:
    (ASIOSMicrophoneAuthorization *)authorization {
    if (authorization != nil) {
        return [self stageMicrophoneAuthorization:authorization] != 0;
    }

    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        [authorization revoke];
        return NO;
    }

    __block BOOL applied = NO;
    [delegate dispatchSync:^{
        if (!self->_initialized) {
            [authorization revoke];
            return;
        }
        if (authorization != nil && [self hostedCallModeIsAuthorized]) {
            atomic_fetch_add_explicit(
                &self->_realtime.recordingRequestCount,
                1,
                memory_order_relaxed
            );
            [authorization revoke];
            [self retireMicrophoneAuthorizationForHostedCall];
            if (self->_inputBusEnabled) {
                [self failAndRollbackWithCode:
                    ASIOSStereoPlayoutFailureMicrophoneBusDisable
                                       status:kAudio_ParamError
                                      message:@"Hosted-call playout rejected a microphone-enable request."];
            }
            return;
        }

        if (authorization == nil || !authorization.isValid) {
            [authorization revoke];
            __attribute__((objc_precise_lifetime))
            ASIOSMicrophoneAuthorization *retiringAuthorization =
                self->_microphoneAuthorization;
            self->_microphoneAuthorization = nil;
            self->_wantsRecording = NO;
            if (retiringAuthorization != authorization) {
                [retiringAuthorization revoke];
            }
            [self closeAndFenceRealtimeMicrophoneResources];
            [self clearCurrentMicrophoneRecordingGeneration];

            BOOL mayRestorePlayback =
                self->_wantsPlayout
                && !self->_interrupted
                && !self->_recoveryRequired
                && !self->_explicitResumeRequired;
            BOOL playbackNeedsRebuild =
                mayRestorePlayback
                && (!self->_playing
                    || !self->_playoutInitialized
                    || !self->_outputBusEnabled
                    || self->_audioUnit == NULL
                    || ![self ownsCurrentSessionActivation]);
            if (self->_inputBusEnabled || playbackNeedsRebuild) {
                applied = [self rebuildForCurrentPolicy];
            } else {
                self->_recording = NO;
                applied = YES;
            }
            return;
        }

        __block ASIOSMicrophoneAuthorization *displacedAuthorization = nil;
        BOOL installed = [authorization performWhileValid:^{
            displacedAuthorization = self->_microphoneAuthorization;
            self->_microphoneAuthorization = authorization;
            self->_wantsRecording = YES;
        }];
        if (!installed) {
            [authorization revoke];
            return;
        }

        __attribute__((objc_precise_lifetime))
        ASIOSMicrophoneAuthorization *retiringAuthorization =
            displacedAuthorization;
        if (retiringAuthorization != authorization) {
            [retiringAuthorization revoke];
        }

        [self closeAndFenceRealtimeMicrophoneResources];

        BOOL hasLiveDuplexTopology =
            self->_inputBusEnabled
            && self->_outputBusEnabled
            && self->_recording
            && self->_playing
            && self->_playoutInitialized
            && self->_audioUnit != NULL
            && self->_recordingSamples != NULL
            && self->_recordingSampleCapacity > 0
            && self->_recordedDataBlock != nil
            && self->_wantsPlayout
            && !self->_interrupted
            && !self->_recoveryRequired
            && !self->_explicitResumeRequired
            && [self ownsCurrentSessionActivation];
        if (hasLiveDuplexTopology) {
            applied = [self
                publishFinalLiveMicrophoneResourcesWithAuthorization:authorization
                                              debugTopologyOverride:NO];
        } else {
            applied = self->_wantsPlayout
                && !self->_interrupted
                && !self->_recoveryRequired
                && !self->_explicitResumeRequired
                && [self rebuildForCurrentPolicy]
                && self->_inputBusEnabled;
        }

        if (!applied && self->_microphoneAuthorization == authorization) {
            [self closeAndFenceRealtimeMicrophoneResources];
            __attribute__((objc_precise_lifetime))
            ASIOSMicrophoneAuthorization *failedAuthorization =
                self->_microphoneAuthorization;
            self->_microphoneAuthorization = nil;
            self->_wantsRecording = NO;
            self->_recording = NO;
            [failedAuthorization revoke];

            // Do not rebuild playback here. The caller must first retire the enable operation
            // and arm an exact playback/disable operation, then call this setter with nil.
        }
    }];
    return applied;
}

#if DEBUG
- (void)debugInstallMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *)authorization {
    [self closeAndFenceRealtimeMicrophoneResources];
    [self clearCurrentMicrophoneRecordingGeneration];
    if (authorization != nil && [self hostedCallModeIsAuthorized]) {
        atomic_fetch_add_explicit(
            &_realtime.recordingRequestCount,
            1,
            memory_order_relaxed
        );
        [authorization revoke];
        [self retireMicrophoneAuthorizationForHostedCall];
        if (_inputBusEnabled) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneBusDisable
                                   status:kAudio_ParamError
                                  message:@"Hosted-call playout rejected a DEBUG microphone-enable request."];
        }
        return;
    }

    __attribute__((objc_precise_lifetime))
    ASIOSMicrophoneAuthorization *retiringAuthorization =
        _microphoneAuthorization;
    [authorization clearMicrophoneRecordingGeneration];
    _microphoneAuthorization = authorization;
    _wantsRecording = authorization != nil;

    if (retiringAuthorization != authorization) {
        [retiringAuthorization revoke];
    }

    if (authorization != nil && authorization.isValid) {
        uint64_t generation =
            [self installNextMicrophoneRecordingGeneration];
        if (![authorization
                bindMicrophoneRecordingGeneration:generation]) {
            [self clearCurrentMicrophoneRecordingGeneration];
            _microphoneAuthorization = nil;
            _wantsRecording = NO;
            [authorization revoke];
        }
    }
}

- (BOOL)debugPublishCurrentMicrophoneAuthorizationForTesting {
    return [self
        publishFinalLiveMicrophoneResourcesWithAuthorization:
            _microphoneAuthorization
                                  debugTopologyOverride:YES];
}

- (BOOL)debugBeginRealtimeAdmissionForTesting {
    os_unfair_lock_lock(&_debugRealtimeAdmissionLock);
    if (_debugAdmittedDeviceGate != NULL
        || _debugAdmittedAuthorizationGate != NULL) {
        os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
        ASFailRealtimeGateInvariant();
    }

    ASRealtimeGate *deviceGate = &_realtimeMicrophoneDeviceGate;
    if (!ASBeginDeviceRealtimeAdmission(deviceGate)) {
        os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
        return NO;
    }

    unsigned long authorizationGateBits = atomic_load_explicit(
        &_realtimeMicrophoneAuthorizationGate,
        memory_order_acquire
    );
    ASRealtimeGate *authorizationGate =
        (ASRealtimeGate *)(uintptr_t)authorizationGateBits;
    if (authorizationGate == NULL
        || !ASBeginAuthorizationRealtimeAdmission(authorizationGate)) {
        ASEndDeviceRealtimeAdmission(deviceGate);
        os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
        return NO;
    }

    if (ASRealtimeGateIsClosed(deviceGate)
        || ASRealtimeGateIsClosed(authorizationGate)) {
        ASEndAuthorizationRealtimeAdmission(authorizationGate);
        ASEndDeviceRealtimeAdmission(deviceGate);
        os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
        return NO;
    }

    uint64_t recordingGeneration = atomic_load_explicit(
        &_realtimeMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    uint64_t approvedRecordingGeneration = atomic_load_explicit(
        &_realtimeApprovedMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    if (recordingGeneration == 0
        || approvedRecordingGeneration != recordingGeneration) {
        ASEndAuthorizationRealtimeAdmission(authorizationGate);
        ASEndDeviceRealtimeAdmission(deviceGate);
        os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
        return NO;
    }

    atomic_fetch_add_explicit(
        &_realtime.microphoneRealtimeAdmissionCount,
        1,
        memory_order_relaxed
    );

    _debugAdmittedDeviceGate = deviceGate;
    _debugAdmittedAuthorizationGate = authorizationGate;
    os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);
    return YES;
}

- (void)debugEndRealtimeAdmissionForTesting {
    os_unfair_lock_lock(&_debugRealtimeAdmissionLock);
    ASRealtimeGate *authorizationGate = _debugAdmittedAuthorizationGate;
    ASRealtimeGate *deviceGate = _debugAdmittedDeviceGate;
    _debugAdmittedAuthorizationGate = NULL;
    _debugAdmittedDeviceGate = NULL;
    os_unfair_lock_unlock(&_debugRealtimeAdmissionLock);

    if (authorizationGate == NULL || deviceGate == NULL) {
        ASFailRealtimeGateInvariant();
    }
    ASEndAuthorizationRealtimeAdmission(authorizationGate);
    ASEndDeviceRealtimeAdmission(deviceGate);
}

- (void)debugCloseAndFenceRealtimeGateForTesting {
    [self closeAndFenceRealtimeMicrophoneResources];
}

- (void)waitForRealtimeGateClosureForTesting {
    dispatch_semaphore_t semaphore = _debugDeviceGateClosureSemaphore;
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (BOOL)debugTerminateForTesting {
    return [self terminateDevice];
}

- (void)debugEnableRecoveryHarnessModeForTesting {
    _debugRecoveryHarnessMode = YES;
    _debugHasOutputRouteOverride = YES;
    _debugHasOutputRoute = YES;
    _debugCaptureRouteIsBuiltInMicrophone = NO;
    _debugOwnsSessionActivation = NO;
}

- (BOOL)debugRemoteIOStartSettlementProductionStateHoldsForTesting {
    const uint64_t configurationGeneration = 11;
    const uint64_t ownershipToken = 91;
    const uint64_t systemAudioGeneration = 41;
    NSString *const preparedRoute = @"prepared-route";
    NSString *const currentRoute = @"current-route";
    NSString *const currentOutput = @"current-output";
    NSString *const unseenPreviousRoute = @"unseen-previous-route";

    void (^installStartingTransaction)(uint64_t, uint64_t) = ^(
        uint64_t transactionIdentifier,
        uint64_t sequenceBaseline
    ) {
        [self clearExpectedMicrophoneRouteChange];
        os_unfair_lock_lock(&self->_expectedMicrophoneRouteChangeLock);
        self->_routeChangeNotificationSequence = sequenceBaseline;
        self->_expectedMicrophoneRouteChangeTransactionIdentifier =
            transactionIdentifier;
        self->_expectedMicrophoneRouteChangeState =
            ASExpectedMicrophoneRouteChangeStateStarting;
        self->_expectedMicrophoneRouteChangeConfigurationGeneration =
            configurationGeneration;
        self->_expectedMicrophoneRouteChangeOwnershipToken = ownershipToken;
        self->_expectedMicrophoneRouteChangeSystemAudioGeneration =
            systemAudioGeneration;
        self->_expectedMicrophoneRouteChangeObserverSequenceBaseline =
            sequenceBaseline;
        self->_expectedMicrophoneRouteChangeDeadlineNanoseconds = UINT64_MAX;
        ASRetireRemoteIOStartSettlement(
            &self->_expectedMicrophoneRouteChangeStartSettlement
        );
        self->_expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence =
            NO;
        self->_expectedMicrophoneRouteChangeTransitionCursorFingerprint =
            [preparedRoute copy];
        self->_expectedMicrophoneRouteChangeConvergedRouteFingerprint =
            [currentRoute copy];
        self->_expectedMicrophoneRouteChangeOutputFingerprint =
            [currentOutput copy];
        self->_expectedMicrophoneRouteChangeTargetInputIdentifier = nil;
        self->_expectedMicrophoneRouteChangeInputRequired = NO;
        self->_expectedMicrophoneRouteChangeRequiresPreferredInput = NO;
        self->_expectedMicrophoneRouteChangeSemaphore =
            dispatch_semaphore_create(0);
        self->_expectedMicrophoneRouteChangeRejectionSnapshot = nil;
        self->_expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
        self->_expectedMicrophoneRouteChangeMutationSequence += 1;
        if (self->_expectedMicrophoneRouteChangeMutationSequence == 0) {
            self->_expectedMicrophoneRouteChangeMutationSequence = 1;
        }
        os_unfair_lock_unlock(&self->_expectedMicrophoneRouteChangeLock);
    };

    ASExpectedRouteObservationSnapshot *(^exactSnapshot)(uint64_t) =
        ^ASExpectedRouteObservationSnapshot *(uint64_t observedAt) {
            ASExpectedRouteObservationSnapshot *snapshot =
                [[ASExpectedRouteObservationSnapshot alloc] init];
            snapshot.currentRouteFingerprint = currentRoute;
            snapshot.currentOutputFingerprint = currentOutput;
            snapshot.currentInputType = nil;
            snapshot.currentInputIdentifier = nil;
            snapshot.preferredInputType = nil;
            snapshot.preferredInputIdentifier = nil;
            snapshot.category = AVAudioSessionCategoryPlayback;
            snapshot.mode = AVAudioSessionModeDefault;
            snapshot.categoryOptions = 0;
            snapshot.sharingPolicy =
                AVAudioSessionRouteSharingPolicyDefault;
            snapshot.inputCount = 0;
            snapshot.outputCount = 1;
            snapshot.inputChannels = 0;
            snapshot.outputChannels = ASOutputChannelCount;
            snapshot.activeConfigurationGeneration =
                configurationGeneration;
            snapshot.currentOwnershipToken = ownershipToken;
            snapshot.systemAudioGeneration = systemAudioGeneration;
            snapshot.sessionActive = YES;
            snapshot.recoveryRequired = NO;
            snapshot.explicitResumeRequired = NO;
            snapshot.observedAt = observedAt;
            snapshot.previousRouteFingerprint = unseenPreviousRoute;
            return snapshot;
        };

    ASExpectedRouteObservationHandling (^processExactReasonEight)(
        uint64_t,
        ASExpectedMicrophoneRouteChangeState,
        uint64_t,
        uint64_t,
        BOOL
    ) = ^ASExpectedRouteObservationHandling(
        uint64_t capturedTransactionIdentifier,
        ASExpectedMicrophoneRouteChangeState entryState,
        uint64_t notificationSequence,
        uint64_t observedAt,
        BOOL belongsToCurrentIngressCount
    ) {
        if (belongsToCurrentIngressCount) {
            os_unfair_lock_lock(&self->_expectedMicrophoneRouteChangeLock);
            self->_routeChangeNotificationSequence = notificationSequence;
            self->_expectedMicrophoneRouteChangeNotificationInFlightCount +=
                1;
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
        }
        return [self
            processExpectedMicrophoneRouteChangeObservationWithReason:
                AVAudioSessionRouteChangeReasonRouteConfigurationChange
            notificationSequence:notificationSequence
            snapshot:exactSnapshot(observedAt)
            transactionIdentifier:capturedTransactionIdentifier
            entryState:entryState
            entryConfigurationGeneration:configurationGeneration
            entrySystemAudioGeneration:systemAudioGeneration
            trackedTransaction:YES];
    };

    BOOL (^commitStartingTransaction)(uint64_t, uint64_t) = ^BOOL(
        uint64_t transactionIdentifier,
        uint64_t now
    ) {
        os_unfair_lock_lock(&self->_expectedMicrophoneRouteChangeLock);
        BOOL committed =
            self->_expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStateStarting
            && self->_expectedMicrophoneRouteChangeTransactionIdentifier
                == transactionIdentifier
            && self->_expectedMicrophoneRouteChangeNotificationInFlightCount
                == 0
            && ASCommitExpectedMicrophoneRouteChangeStartState(
                &self->_expectedMicrophoneRouteChangeState,
                &self->_expectedMicrophoneRouteChangeStartSettlement,
                transactionIdentifier,
                now
            );
        if (committed) {
            self->_expectedMicrophoneRouteChangeMutationSequence += 1;
            if (self->_expectedMicrophoneRouteChangeMutationSequence == 0) {
                self->_expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        }
        os_unfair_lock_unlock(&self->_expectedMicrophoneRouteChangeLock);
        return committed;
    };

    // First drive the original replay failure through the production ivar state and production
    // observation processor: stamp -> exact Starting ingress -> commit -> unchained replay.
    installStartingTransaction(71, 43);
    BOOL startingClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement startingSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t startingCompletedAt = startingSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    uint64_t startingObservationAt = startingCompletedAt + 250000000;
    ASExpectedRouteObservationHandling startingHandling =
        processExactReasonEight(
            71,
            ASExpectedMicrophoneRouteChangeStateStarting,
            44,
            startingObservationAt,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL startingClaimWasConsumedLive =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateStarting
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    BOOL liveConsumptionCommitted =
        commitStartingTransaction(71, startingObservationAt + 1);
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL liveConsumptionPublishedWithoutClaim =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateConsumed
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    ASExpectedRouteObservationHandling startingReplayHandling =
        processExactReasonEight(
            71,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            45,
            startingObservationAt + 2,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL startingReplayWasRejected =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateRejected
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // Also cover a synchronous notification admitted during AudioOutputUnitStart before its
    // return-boundary stamp. Stamping must preserve the already-consumed state, never re-arm it.
    installStartingTransaction(70, 33);
    uint64_t preStampObservationAt = ASMonotonicNanoseconds();
    ASExpectedRouteObservationHandling preStampHandling =
        processExactReasonEight(
            70,
            ASExpectedMicrophoneRouteChangeStateStarting,
            34,
            preStampObservationAt,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL preStampConsumptionWasRecorded =
        _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting
        && _expectedMicrophoneRouteChangeStartSettlement
                .transactionIdentifier == 70
        && _expectedMicrophoneRouteChangeStartSettlement.deadlineNanoseconds
            == 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    BOOL consumedClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement preStampSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    BOOL stampPreservedLiveConsumption =
        preStampSettlement.state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting
        && preStampSettlement.notificationSequenceBaseline == 34
        && preStampSettlement.deadlineNanoseconds != 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t preStampCompletedAt = preStampSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    BOOL preStampConsumptionCommitted =
        commitStartingTransaction(70, preStampCompletedAt + 1);
    ASExpectedRouteObservationHandling preStampReplayHandling =
        processExactReasonEight(
            70,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            35,
            preStampCompletedAt + 250000000,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL preStampReplayWasRejected =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateRejected
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // An unused Armed claim survives commit, but only one delayed exact ingress may consume it.
    installStartingTransaction(72, 53);
    BOOL delayedClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement delayedSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t delayedCompletedAt = delayedSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    BOOL unusedClaimCommitted =
        commitStartingTransaction(72, delayedCompletedAt + 1);
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL unusedClaimRemainedArmed =
        _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateArmed;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    ASExpectedRouteObservationHandling delayedHandling =
        processExactReasonEight(
            72,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            54,
            delayedCompletedAt + 250000000,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL delayedClaimWasRetired =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateConsumed
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    ASExpectedRouteObservationHandling delayedReplayHandling =
        processExactReasonEight(
            72,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            55,
            delayedCompletedAt + 250000001,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL delayedReplayWasRejected =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateRejected;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // Expiry is evaluated at immutable ingress time, not at evidence-queue processing time.
    installStartingTransaction(73, 63);
    BOOL expiringClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement expiringSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t expiringCompletedAt = expiringSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    BOOL expiringClaimCommitted =
        commitStartingTransaction(73, expiringCompletedAt + 1);
    ASExpectedRouteObservationHandling expiredHandling =
        processExactReasonEight(
            73,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            64,
            expiringSettlement.deadlineNanoseconds + 1,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL expiredObservationWasRejected =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateRejected;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // A queued observation from another transaction cannot spend or retire the current claim.
    installStartingTransaction(74, 73);
    BOOL wrongTransactionClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement wrongTransactionSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t wrongTransactionCompletedAt =
        wrongTransactionSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    BOOL wrongTransactionClaimCommitted =
        commitStartingTransaction(74, wrongTransactionCompletedAt + 1);
    ASExpectedRouteObservationHandling wrongTransactionHandling =
        processExactReasonEight(
            75,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            74,
            wrongTransactionCompletedAt + 250000000,
            NO
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL wrongTransactionPreservedClaim =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateConsumed
        && _expectedMicrophoneRouteChangeTransactionIdentifier == 74
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateArmed;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    [self clearExpectedMicrophoneRouteChange];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL clearRetiredClaim =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateNone
        && _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // A same-transaction observation at the stamp's sequence baseline is not new evidence.
    installStartingTransaction(76, 83);
    BOOL oldSequenceClaimWasStamped =
        [self markExpectedMicrophoneRouteChangeAudioUnitStartCompleted];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASRemoteIOStartSettlement oldSequenceSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    uint64_t oldSequenceCompletedAt =
        oldSequenceSettlement.deadlineNanoseconds
        - ASRemoteIOStartSettlementLifetimeNanoseconds;
    BOOL oldSequenceClaimCommitted =
        commitStartingTransaction(76, oldSequenceCompletedAt + 1);
    ASExpectedRouteObservationHandling oldSequenceHandling =
        processExactReasonEight(
            76,
            ASExpectedMicrophoneRouteChangeStateConsumed,
            83,
            oldSequenceCompletedAt + 250000000,
            YES
        );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL oldSequenceWasRejected =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateRejected;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    [self clearExpectedMicrophoneRouteChange];

    return startingClaimWasStamped
        && startingHandling == ASExpectedRouteObservationHandlingConsumed
        && startingClaimWasConsumedLive
        && liveConsumptionCommitted
        && liveConsumptionPublishedWithoutClaim
        && startingReplayHandling
            == ASExpectedRouteObservationHandlingGeneric
        && startingReplayWasRejected
        && preStampObservationAt != 0
        && preStampHandling == ASExpectedRouteObservationHandlingConsumed
        && preStampConsumptionWasRecorded
        && consumedClaimWasStamped
        && stampPreservedLiveConsumption
        && preStampConsumptionCommitted
        && preStampReplayHandling == ASExpectedRouteObservationHandlingGeneric
        && preStampReplayWasRejected
        && delayedClaimWasStamped
        && unusedClaimCommitted
        && unusedClaimRemainedArmed
        && delayedHandling == ASExpectedRouteObservationHandlingConsumed
        && delayedClaimWasRetired
        && delayedReplayHandling == ASExpectedRouteObservationHandlingGeneric
        && delayedReplayWasRejected
        && expiringClaimWasStamped
        && expiringClaimCommitted
        && expiredHandling == ASExpectedRouteObservationHandlingGeneric
        && expiredObservationWasRejected
        && wrongTransactionClaimWasStamped
        && wrongTransactionClaimCommitted
        && wrongTransactionHandling == ASExpectedRouteObservationHandlingGeneric
        && wrongTransactionPreservedClaim
        && clearRetiredClaim
        && oldSequenceClaimWasStamped
        && oldSequenceClaimCommitted
        && oldSequenceHandling == ASExpectedRouteObservationHandlingGeneric
        && oldSequenceWasRejected;
}

- (void)debugRecordAudioPolicyConfiguration:
    (ASAudioPolicyConfiguration)configuration {
    _debugConfigurationOperationCount += 1;
    _debugHasRecordedAudioPolicyConfiguration = YES;
    _debugLastConfiguredCategory =
        [ASCategoryForAudioPolicyConfiguration(configuration) copy];
    _debugLastConfiguredMode = [AVAudioSessionModeDefault copy];
    _debugLastConfiguredRouteSharingPolicy = configuration.routeSharingPolicy;
    _debugLastConfiguredCategoryOptions = configuration.categoryOptions;
    _debugLastConfiguredInputBusEnabled = configuration.inputBusEnabled;
    _debugLastConfiguredOutputBusEnabled = configuration.outputBusEnabled;
    _debugLastConfiguredOutputStreamFormat = configuration.outputStreamFormat;
}

- (NSUInteger)debugConfigurationOperationCountForTesting {
    return _debugConfigurationOperationCount;
}

- (NSString *)debugLastConfiguredCategoryForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        ? [_debugLastConfiguredCategory copy]
        : nil;
}

- (NSString *)debugLastConfiguredModeForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        ? [_debugLastConfiguredMode copy]
        : nil;
}

- (NSInteger)debugLastConfiguredRouteSharingPolicyForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        ? _debugLastConfiguredRouteSharingPolicy
        : NSNotFound;
}

- (NSUInteger)debugLastConfiguredCategoryOptionsForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        ? _debugLastConfiguredCategoryOptions
        : 0;
}

- (BOOL)debugLastConfiguredInputBusEnabledForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        && _debugLastConfiguredInputBusEnabled;
}

- (BOOL)debugLastConfiguredOutputBusEnabledForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        && _debugLastConfiguredOutputBusEnabled;
}

- (AudioStreamBasicDescription)debugLastConfiguredOutputStreamFormatForTesting {
    return _debugHasRecordedAudioPolicyConfiguration
        ? _debugLastConfiguredOutputStreamFormat
        : (AudioStreamBasicDescription){0};
}

- (NSUUID *)debugHostedCallPolicyIdentifierForTesting {
    return [_hostedCallPolicyIdentifier copy];
}

- (void)debugMarkInterruptedFailClosedForTesting {
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    [self closeAndFenceRealtimeMicrophoneResources];
    (void)[self stopAndDisposeAudioUnit];
    (void)[self deactivateOwnedSessionWithError:nil];

    _debugHealthyPlayoutForTesting = NO;
    _debugHasOutputRouteOverride = YES;
    _debugHasOutputRoute = YES;
    _debugOwnsSessionActivation = NO;
    _wantsPlayout = YES;
    _interrupted = YES;
    _recoveryRequired = YES;
    _explicitResumeRequired = NO;
    atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
    atomic_store_explicit(
        &_lifecycle.explicitResumeRequired,
        false,
        memory_order_relaxed
    );
    [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                     status:noErr
                    message:@"Audio interruption began; playout is fail-closed."];
}

- (void)debugMarkInterruptionEndedFailClosedForTesting {
    [self handleSystemEvent:ASSystemAudioEventInterruptionEnded
                routeReason:AVAudioSessionRouteChangeReasonUnknown];
}

- (void)debugMarkHealthyPlayoutForTesting {
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    [self closeAndFenceRealtimeMicrophoneResources];
    (void)[self stopAndDisposeAudioUnit];
    (void)[self deactivateOwnedSessionWithError:nil];

    _debugHealthyPlayoutForTesting = NO;
    _debugHasOutputRouteOverride = YES;
    _debugHasOutputRoute = YES;
    _debugOwnsSessionActivation = NO;
    _wantsPlayout = YES;
    _interrupted = NO;
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(
        &_lifecycle.explicitResumeRequired,
        false,
        memory_order_relaxed
    );
    (void)[self rebuildForCurrentPolicy];
}

- (BOOL)debugConsumedPublicationRetainsRecordedRouteClosureForTesting {
    [self closeAndFenceRealtimePlayoutResources];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL canExercisePublication =
        atomic_load_explicit(
            &_lifecycle.playing,
            memory_order_acquire
        );
    if (canExercisePublication) {
        if (_expectedMicrophoneRouteChangeTransactionIdentifier == 0) {
            _expectedMicrophoneRouteChangeTransactionIdentifier = 71;
        }
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
        _expectedMicrophoneRouteChangeState =
            ASExpectedMicrophoneRouteChangeStateConsumed;
        _expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
        _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence = YES;
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (!canExercisePublication) {
        return NO;
    }

    BOOL published = [self publishCommittedExpectedMicrophoneRouteChangePlayout];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL closureRetained =
        _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence
        && ASRealtimeGateIsClosedAndDrained(
            &_realtimePlayoutDeviceGate
        );
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return published && closureRetained;
}

- (BOOL)debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting {
    ASExpectedRouteObservationSnapshot *snapshot =
        [[ASExpectedRouteObservationSnapshot alloc] init];
    snapshot.previousRouteFingerprint = @"previous-PRIVATE-UID";
    snapshot.currentRouteFingerprint = @"rejected-PRIVATE-UID";
    snapshot.currentOutputFingerprint = @"output-PRIVATE-UID";
    snapshot.currentInputType = AVAudioSessionPortBuiltInMic;
    snapshot.currentInputIdentifier = @"input-PRIVATE-UID";
    snapshot.preferredInputType = AVAudioSessionPortBuiltInMic;
    snapshot.preferredInputIdentifier = @"preferred-PRIVATE-UID";
    snapshot.category = AVAudioSessionCategoryPlayAndRecord;
    snapshot.mode = AVAudioSessionModeDefault;
    snapshot.categoryOptions = ASIPhoneMicrophoneCategoryOptions();
    snapshot.sharingPolicy = AVAudioSessionRouteSharingPolicyDefault;
    snapshot.inputCount = 1;
    snapshot.outputCount = 1;
    snapshot.inputChannels = ASInputChannelCount;
    snapshot.outputChannels = ASOutputChannelCount;
    snapshot.activeConfigurationGeneration = 11;
    snapshot.currentOwnershipToken = 91;
    snapshot.systemAudioGeneration = 41;
    snapshot.sessionActive = YES;
    snapshot.observedAt = 123456;
    NSString *stored = ASImmutableRouteObservationRejectionDescription(
        snapshot,
        AVAudioSessionRouteChangeReasonRouteConfigurationChange,
        73,
        71,
        ASExpectedMicrophoneRouteChangeStateStarting,
        11,
        41,
        91
    );
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    _expectedMicrophoneRouteChangeRejectionSnapshot = [stored copy];
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStateRejected;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    snapshot.currentRouteFingerprint = @"later-PRIVATE-UID";
    snapshot.currentOutputFingerprint = @"later-output-PRIVATE-UID";
    NSString *reported = [self
        routeTransactionFailureSnapshotForPhase:
            ASRouteTransactionDiagnosticPhaseObservationRejection
        session:nil
        expectedTransactionIdentifier:0
        requiredNotificationSequence:0];
    BOOL immutableSnapshotSurvived = [reported isEqualToString:stored]
        && [reported containsString:@"ingress=immutable"]
        && ![reported containsString:@"PRIVATE-UID"];
    [self clearExpectedMicrophoneRouteChange];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL retiredSnapshotWasCleared =
        _expectedMicrophoneRouteChangeRejectionSnapshot == nil;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return immutableSnapshotSurvived && retiredSnapshotWasCleared;
}

- (void)debugMarkRouteLossForTesting {
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    [self closeAndFenceRealtimeMicrophoneResources];
    (void)[self stopAndDisposeAudioUnit];
    (void)[self deactivateOwnedSessionWithError:nil];

    _debugHealthyPlayoutForTesting = NO;
    _debugHasOutputRouteOverride = YES;
    _debugHasOutputRoute = NO;
    _debugOwnsSessionActivation = NO;
    _wantsPlayout = YES;
    _interrupted = NO;
    _recoveryRequired = YES;
    _explicitResumeRequired = YES;
    atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
    atomic_store_explicit(
        &_lifecycle.explicitResumeRequired,
        true,
        memory_order_relaxed
    );
    [self publishFailureCode:
        ASIOSStereoPlayoutFailureRouteRequiresExplicitResume
                     status:noErr
                    message:@"The prior output device became unavailable; explicit resume is required before speaker playout."];
}

- (BOOL)debugClearRetiresInFlightExpectedRouteObservationForTesting {
    [self clearExpectedMicrophoneRouteChange];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    _expectedMicrophoneRouteChangeTransactionIdentifierCounter += 1;
    if (_expectedMicrophoneRouteChangeTransactionIdentifierCounter == 0) {
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 1;
    }
    uint64_t oldIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
    _expectedMicrophoneRouteChangeTransactionIdentifier = oldIdentifier;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStateStarting;
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 1;
    _expectedMicrophoneRouteChangeSemaphore =
        dispatch_semaphore_create(0);
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    [self clearExpectedMicrophoneRouteChange];

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL retired =
        _expectedMicrophoneRouteChangeTransactionIdentifier == 0
        && _expectedMicrophoneRouteChangeTransactionIdentifier
            != oldIdentifier
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateNone;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return retired;
}

- (BOOL)debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting {
    [self clearExpectedMicrophoneRouteChange];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    _expectedMicrophoneRouteChangeTransactionIdentifierCounter += 1;
    if (_expectedMicrophoneRouteChangeTransactionIdentifierCounter == 0) {
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 1;
    }
    uint64_t oldIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
    _expectedMicrophoneRouteChangeTransactionIdentifier = oldIdentifier;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStateStarting;
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 1;
    _expectedMicrophoneRouteChangeSemaphore = dispatch_semaphore_create(0);

    dispatch_semaphore_t oldSemaphore =
        [self clearExpectedMicrophoneRouteChangeWhileHoldingLock];
    _expectedMicrophoneRouteChangeTransactionIdentifierCounter += 1;
    if (_expectedMicrophoneRouteChangeTransactionIdentifierCounter == 0) {
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 1;
    }
    uint64_t newIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
    _expectedMicrophoneRouteChangeTransactionIdentifier = newIdentifier;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStatePending;
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 1;
    _expectedMicrophoneRouteChangeSemaphore = dispatch_semaphore_create(0);

    // This is the production completion identity check. A queued completion
    // carrying the retired ID must not decrement, signal, reject, or otherwise
    // mutate the newly armed transaction.
    BOOL oldCompletionMatches =
        ASQueuedRouteObservationMatchesTransactionIdentifier(
            oldIdentifier,
            _expectedMicrophoneRouteChangeTransactionIdentifier
        );
    if (oldCompletionMatches) {
        _expectedMicrophoneRouteChangeNotificationInFlightCount -= 1;
    }
    BOOL newTransactionWasPreserved = !oldCompletionMatches
        && newIdentifier != oldIdentifier
        && _expectedMicrophoneRouteChangeTransactionIdentifier
            == newIdentifier
        && _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 1;
    dispatch_semaphore_t newSemaphore =
        [self clearExpectedMicrophoneRouteChangeWhileHoldingLock];
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (oldSemaphore != nil) {
        dispatch_semaphore_signal(oldSemaphore);
    }
    if (newSemaphore != nil) {
        dispatch_semaphore_signal(newSemaphore);
    }
    return newTransactionWasPreserved;
}

- (BOOL)debugDriveRetiredExpectedCategoryObservationForTestingWithExactPolicy:
    (BOOL)exactPolicy {
    dispatch_semaphore_t evidenceQueueEntered =
        dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseEvidenceQueue =
        dispatch_semaphore_create(0);
    dispatch_async(_expectedMicrophoneRouteChangeEvidenceQueue, ^{
        dispatch_semaphore_signal(evidenceQueueEntered);
        dispatch_semaphore_wait(
            releaseEvidenceQueue,
            DISPATCH_TIME_FOREVER
        );
    });
    if (dispatch_semaphore_wait(
            evidenceQueueEntered,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)
        ) != 0) {
        dispatch_semaphore_signal(releaseEvidenceQueue);
        return NO;
    }

    [self clearExpectedMicrophoneRouteChange];
    atomic_store_explicit(
        &_activeAudioConfigurationGeneration,
        11,
        memory_order_release
    );
    atomic_store_explicit(
        &_systemAudioGeneration,
        41,
        memory_order_release
    );

    NSNotification *notification = [NSNotification
        notificationWithName:AVAudioSessionRouteChangeNotification
        object:nil
        userInfo:@{
            AVAudioSessionRouteChangeReasonKey:
                @(AVAudioSessionRouteChangeReasonCategoryChange),
        }];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    _expectedMicrophoneRouteChangeTransactionIdentifierCounter += 1;
    if (_expectedMicrophoneRouteChangeTransactionIdentifierCounter == 0) {
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 1;
    }
    _expectedMicrophoneRouteChangeTransactionIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStatePending;
    _expectedMicrophoneRouteChangeConfigurationGeneration = 11;
    _expectedMicrophoneRouteChangeSystemAudioGeneration = 41;
    _expectedMicrophoneRouteChangeObserverSequenceBaseline =
        _routeChangeNotificationSequence;
    _expectedMicrophoneRouteChangeDeadlineNanoseconds = UINT64_MAX;
    _expectedMicrophoneRouteChangeInputRequired = YES;
    _expectedMicrophoneRouteChangeSemaphore =
        dispatch_semaphore_create(0);
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
    _expectedMicrophoneRouteChangeMutationSequence += 1;
    if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
        _expectedMicrophoneRouteChangeMutationSequence = 1;
    }
    _debugExpectedCategoryObservationNotification = notification;
    _debugExpectedCategoryObservationCategory =
        AVAudioSessionCategoryPlayAndRecord;
    _debugExpectedCategoryObservationMode = AVAudioSessionModeDefault;
    _debugExpectedCategoryObservationOptions = exactPolicy
        ? ASIPhoneMicrophoneCategoryOptions()
        : 0;
    _debugExpectedCategoryObservationSharingPolicy =
        AVAudioSessionRouteSharingPolicyDefault;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    [self enqueueExpectedMicrophoneRouteChangeNotification:notification
                                                   reason:
                                                       AVAudioSessionRouteChangeReasonCategoryChange
                                           resolverToken:
                                               ASInvalidRouteConfigurationChangeResolverToken];
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL overrideWasConsumed =
        _debugExpectedCategoryObservationNotification == nil;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    // Retire the transaction before the captured observation reaches the
    // evidence queue, reproducing the delayed ownership race deterministically.
    [self clearExpectedMicrophoneRouteChange];
    _wantsRecording = NO;
    _microphoneAuthorization = nil;
    _debugHasRecordedAudioPolicyConfiguration = YES;
    _debugLastConfiguredCategory = AVAudioSessionCategoryPlayAndRecord;
    _debugLastConfiguredMode = AVAudioSessionModeDefault;
    _debugLastConfiguredRouteSharingPolicy =
        AVAudioSessionRouteSharingPolicyDefault;
    _debugLastConfiguredCategoryOptions =
        ASIPhoneMicrophoneCategoryOptions();
    _debugLastConfiguredInputBusEnabled = YES;
    _debugLastConfiguredOutputBusEnabled = YES;
    _debugLastConfiguredOutputStreamFormat = _streamFormat;

    dispatch_semaphore_signal(releaseEvidenceQueue);
    dispatch_sync(_expectedMicrophoneRouteChangeEvidenceQueue, ^{});
    return overrideWasConsumed;
}

- (void)debugAdvanceSystemAudioGenerationForTesting {
    BOOL hadHostedCallPolicy = _hostedCallAuthorization != nil;
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    if (hadHostedCallPolicy) {
        [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
            @"Hosted-call system-audio generation advanced; native audio remains quiescent until fresh application recovery."];
    }
}

- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available {
    _debugHasOutputRouteOverride = YES;
    _debugHasOutputRoute = available;
}

- (void)debugSetCaptureRouteBuiltInMicrophoneForTesting:
    (BOOL)isBuiltIn {
    _debugCaptureRouteIsBuiltInMicrophone = isBuiltIn;
    if (!isBuiltIn) {
        atomic_store_explicit(
            &_captureRouteProofGeneration,
            0,
            memory_order_release
        );
    }
}

- (void)debugFailNextHostedCallActivationForTesting {
    _debugFailNextHostedCallActivation = YES;
}
#endif

- (void)requestPlayoutRecoveryWithAuthorization:
    (ASIOSStereoPlayoutRecoveryAuthorization *)authorization {
    atomic_fetch_add_explicit(&_realtime.recoveryRequestCount, 1, memory_order_relaxed);
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (!authorization.isValid) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        return;
    }
    if (delegate == nil) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        [authorization reject];
        return;
    }
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil) {
            [authorization reject];
            return;
        }
        if (!self->_initialized) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
            [authorization reject];
            return;
        }

        BOOL accepted =
            [authorization performIfValidReturningAcceptance:^BOOL{
            if ([self hostedCallModeIsAuthorized]) {
                [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                                 status:noErr
                                message:@"Ordinary recovery cannot replace a live hosted-call policy."];
                return NO;
            }

            // App lifecycle signals may request recovery while healthy playout is already running.
            // Treat those signals as idempotent: rebuilding RemoteIO would introduce an audible gap
            // and briefly relinquish an otherwise valid media-playback audio session.
            AVAudioSession *session = [self currentAudioSession];
            BOOL healthyPlayout = !self->_recoveryRequired
                && !self->_explicitResumeRequired
                && self->_playing
                && self->_playoutInitialized
                && self->_audioUnit != NULL
                && [self ownsCurrentSessionActivation]
                && [self sessionMatchesCurrentPolicy:session]
                && [self hasOutputRouteForSession:session];
#if DEBUG
            if (self->_debugRecoveryHarnessMode
                && self->_debugHealthyPlayoutForTesting
                && self->_sessionActive
                && self->_playing
                && self->_playoutInitialized
                && self->_outputBusEnabled
                && [self ownsCurrentSessionActivation]
                && [self sessionMatchesCurrentPolicy:session]
                && [self hasOutputRouteForSession:session]) {
                healthyPlayout = YES;
            }
#endif
            if (healthyPlayout) {
#if DEBUG
                if (self->_debugRecoveryHarnessMode) {
                    return YES;
                }
#endif
                return [self startPlayout];
            }
            if (self->_interrupted) {
                [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                                 status:noErr
                                message:@"Audio remains interrupted; explicit recovery cannot start yet."];
                return NO;
            }
            self->_recoveryRequired = NO;
            self->_explicitResumeRequired = NO;
            atomic_store_explicit(&self->_lifecycle.recoveryRequired, false, memory_order_relaxed);
            atomic_store_explicit(
                &self->_lifecycle.explicitResumeRequired,
                false,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryRebuildCount,
                1,
                memory_order_relaxed
            );
            return [self rebuildAfterExplicitRecovery];
        }];
        if (!accepted) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
        }
    }];
}

- (BOOL)armStartupConnectedCallPlayoutWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization {
    atomic_fetch_add_explicit(
        &_realtime.recoveryRequestCount,
        1,
        memory_order_relaxed
    );
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (authorization == nil
        || !authorization.isValid
        || authorization.origin
            != ASIOSHostedCallPlayoutOriginStartupConnectedCall
        || authorization.policyIdentifier == nil
        || delegate == nil) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        if (authorization.isValid) {
            [authorization revoke];
        }
        return NO;
    }

    NSUUID *policyIdentifier = [authorization.policyIdentifier copy];
    __block BOOL accepted = NO;
    __block BOOL duplicate = NO;
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchSync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil) {
            return;
        }

        uint64_t currentGeneration = atomic_load_explicit(
            &self->_systemAudioGeneration,
            memory_order_acquire
        );
        BOOL exactInstalledPolicy = currentGeneration != 0
            && authorization.isValid
            && !authorization.isRecoveryPending
            && authorization.origin
                == ASIOSHostedCallPlayoutOriginStartupConnectedCall
            && self->_hostedCallAuthorization == authorization
            && self->_hostedCallPolicyIdentifier != nil
            && [self->_hostedCallPolicyIdentifier
                isEqual:policyIdentifier]
            && self->_hostedCallAuthorizationGeneration == currentGeneration
            && authorization.systemAudioGeneration == currentGeneration
            && [self hostedCallModeIsAuthorized];
        if (exactInstalledPolicy) {
            duplicate = YES;
            accepted = YES;
            return;
        }

        BOOL ownsSessionActivation = [self ownsCurrentSessionActivation];
        BOOL microphoneGateIsClosed =
            ASRealtimeGateIsClosedAndDrained(
                &self->_realtimeMicrophoneDeviceGate
            )
            && atomic_load_explicit(
                &self->_realtimeMicrophoneAuthorizationGate,
                memory_order_acquire
            ) == 0;
        BOOL microphoneGenerationsAreRetired =
            atomic_load_explicit(
                &self->_realtimeMicrophoneRecordingGeneration,
                memory_order_acquire
            ) == 0
            && atomic_load_explicit(
                &self->_realtimeApprovedMicrophoneRecordingGeneration,
                memory_order_acquire
            ) == 0;
        BOOL quiescent = self->_initialized
            && currentGeneration != 0
            && !self->_interrupted
            && !self->_wantsPlayout
            && !self->_wantsRecording
            && !self->_recording
            && !self->_recoveryRequired
            && !self->_explicitResumeRequired
            && !self->_isRebuilding
            && !self->_playoutInitialized
            && !self->_playing
            && !self->_sessionActive
            && !ownsSessionActivation
            && self->_audioUnit == NULL
            && !self->_inputBusEnabled
            && !self->_outputBusEnabled
            && self->_recordingSamples == NULL
            && self->_recordingSampleCapacity == 0
            && self->_microphoneAuthorization == nil
            && microphoneGateIsClosed
            && microphoneGenerationsAreRetired
            && self->_hostedCallAuthorization == nil
            && self->_hostedCallRecoveryInProgressAuthorization == nil
            && self->_hostedCallPolicyIdentifier == nil
            && self->_hostedCallAuthorizationGeneration == 0
            && authorization.isRecoveryPending
            && authorization.systemAudioGeneration == 0;
#if DEBUG
        if (self->_debugFailNextHostedCallActivation) {
            self->_debugFailNextHostedCallActivation = NO;
            quiescent = NO;
        }
#endif
        if (!quiescent) {
            return;
        }

        __block BOOL consumeRecoveryClaim = NO;
        BOOL didConsume = [authorization performRecoveryIfValid:^{
            uint64_t exactGeneration = atomic_load_explicit(
                &self->_systemAudioGeneration,
                memory_order_acquire
            );
            BOOL stillQuiescent = exactGeneration == currentGeneration
                && self->_initialized
                && !self->_interrupted
                && !self->_wantsPlayout
                && !self->_wantsRecording
                && !self->_recording
                && !self->_recoveryRequired
                && !self->_explicitResumeRequired
                && !self->_isRebuilding
                && !self->_playoutInitialized
                && !self->_playing
                && !self->_sessionActive
                && ![self ownsCurrentSessionActivation]
                && self->_audioUnit == NULL
                && !self->_inputBusEnabled
                && !self->_outputBusEnabled
                && self->_recordingSamples == NULL
                && self->_recordingSampleCapacity == 0
                && self->_microphoneAuthorization == nil
                && ASRealtimeGateIsClosedAndDrained(
                    &self->_realtimeMicrophoneDeviceGate
                )
                && atomic_load_explicit(
                    &self->_realtimeMicrophoneAuthorizationGate,
                    memory_order_acquire
                ) == 0
                && atomic_load_explicit(
                    &self->_realtimeMicrophoneRecordingGeneration,
                    memory_order_acquire
                ) == 0
                && atomic_load_explicit(
                    &self->_realtimeApprovedMicrophoneRecordingGeneration,
                    memory_order_acquire
                ) == 0
                && self->_hostedCallAuthorization == nil
                && self->_hostedCallRecoveryInProgressAuthorization == nil
                && self->_hostedCallPolicyIdentifier == nil
                && self->_hostedCallAuthorizationGeneration == 0;
            if (!stillQuiescent) {
                return;
            }

            __weak ASIOSStereoPlayoutAudioDevice *weakDevice = self;
            __weak ASIOSHostedCallPlayoutAuthorization *weakAuthorization =
                authorization;
            BOOL handlerInstalled = [authorization
                installRevocationHandlerWhilePerforming:^{
                    ASIOSStereoPlayoutAudioDevice *device = weakDevice;
                    ASIOSHostedCallPlayoutAuthorization *liveAuthorization =
                        weakAuthorization;
                    if (device == nil || liveAuthorization == nil) {
                        return;
                    }
                    [device hostedCallAuthorizationDidRevoke:liveAuthorization
                                             policyIdentifier:policyIdentifier
                                                    generation:currentGeneration];
                }
                              systemAudioGeneration:currentGeneration];
            if (!handlerInstalled) {
                return;
            }

            self->_hostedCallAuthorization = authorization;
            self->_hostedCallPolicyIdentifier = [policyIdentifier copy];
            self->_hostedCallAuthorizationGeneration = currentGeneration;
            [self publishHostedCallLifecycleState];
            consumeRecoveryClaim =
                self->_hostedCallAuthorization == authorization
                && self->_hostedCallPolicyIdentifier != nil
                && [self->_hostedCallPolicyIdentifier
                    isEqual:policyIdentifier]
                && self->_hostedCallAuthorizationGeneration
                    == currentGeneration
                && [self hostedCallModeIsAuthorized]
                && !self->_sessionActive
                && !self->_playoutInitialized
                && !self->_playing
                && self->_audioUnit == NULL
                && !self->_inputBusEnabled
                && !self->_outputBusEnabled;
        }
                   consumeRecoveryClaim:&consumeRecoveryClaim];
        accepted = didConsume && consumeRecoveryClaim;
        [self publishHostedCallLifecycleState];
    }];

    if (!accepted) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        if (authorization.isValid) {
            [authorization revoke];
        }
    } else if (!duplicate) {
        [self clearLifecycleFailure];
    }
    return accepted;
}

- (void)requestHostedCallPlayoutRecoveryWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization {
    atomic_fetch_add_explicit(
        &_realtime.recoveryRequestCount,
        1,
        memory_order_relaxed
    );
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (!authorization.isValid
        || !authorization.isRecoveryPending
        || authorization.origin
            != ASIOSHostedCallPlayoutOriginInterruption) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        return;
    }
    if (delegate == nil) {
        atomic_fetch_add_explicit(
            &_realtime.recoveryAuthorizationRejectionCount,
            1,
            memory_order_relaxed
        );
        [authorization revoke];
        return;
    }

    uint64_t expectedSystemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    NSUUID *policyIdentifier = [authorization.policyIdentifier copy];
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil) {
            [authorization revoke];
            return;
        }
        if (!self->_initialized) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
            [authorization revoke];
            return;
        }

        ASHostedCallRecoveryReadiness readiness = [self
            hostedCallRecoveryReadinessForAuthorization:authorization
                            expectedSystemAudioGeneration:
                                expectedSystemAudioGeneration];
        if (readiness == ASHostedCallRecoveryReadinessAwaitingFailClose) {
            return;
        }
        if (readiness == ASHostedCallRecoveryReadinessCoalesced) {
            // The exact authorization/policy/generation already owns the live policy. This queued
            // stale duplicate is an idempotent no-op: do not consume, reject, revoke, or rebuild.
            return;
        }
        if (readiness == ASHostedCallRecoveryReadinessRejected) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
            [authorization revoke];
            return;
        }

        __block BOOL attempted = NO;
        __block BOOL accepted = NO;
        BOOL authorized = [authorization performRecoveryIfValid:^{
            if (atomic_load_explicit(
                    &self->_systemAudioGeneration,
                    memory_order_acquire
                ) != expectedSystemAudioGeneration
                || [self
                    hostedCallRecoveryReadinessForAuthorization:authorization
                                    expectedSystemAudioGeneration:
                                        expectedSystemAudioGeneration]
                    != ASHostedCallRecoveryReadinessReady) {
                return;
            }

            attempted = YES;
            [self retireMicrophoneAuthorizationForHostedCall];

            __weak ASIOSStereoPlayoutAudioDevice *weakDevice = self;
            __weak ASIOSHostedCallPlayoutAuthorization *weakAuthorization =
                authorization;
            BOOL handlerInstalled = [authorization
                installRevocationHandlerWhilePerforming:^{
                    ASIOSStereoPlayoutAudioDevice *device = weakDevice;
                    ASIOSHostedCallPlayoutAuthorization *liveAuthorization =
                        weakAuthorization;
                    if (device == nil || liveAuthorization == nil) {
                        return;
                    }
                    [device hostedCallAuthorizationDidRevoke:liveAuthorization
                                             policyIdentifier:policyIdentifier
                                                    generation:
                                                        expectedSystemAudioGeneration];
                }
                              systemAudioGeneration:
                                  expectedSystemAudioGeneration];
            if (!handlerInstalled) {
                return;
            }

            self->_hostedCallRecoveryInProgressAuthorization = authorization;
            self->_hostedCallAuthorization = authorization;
            self->_hostedCallPolicyIdentifier = [policyIdentifier copy];
            self->_hostedCallAuthorizationGeneration =
                expectedSystemAudioGeneration;
            [self publishHostedCallLifecycleState];

            self->_recoveryRequired = NO;
            self->_explicitResumeRequired = NO;
            atomic_store_explicit(
                &self->_lifecycle.recoveryRequired,
                false,
                memory_order_relaxed
            );
            atomic_store_explicit(
                &self->_lifecycle.explicitResumeRequired,
                false,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryRebuildCount,
                1,
                memory_order_relaxed
            );

            BOOL rebuilt = [self rebuildAfterExplicitRecovery];
            AVAudioSession *session = [self currentAudioSession];
            BOOL microphoneGateClosed = ASRealtimeGateIsClosedAndDrained(
                    &self->_realtimeMicrophoneDeviceGate
                )
                && atomic_load_explicit(
                    &self->_realtimeMicrophoneAuthorizationGate,
                    memory_order_acquire
                ) == 0;
            BOOL topologyIsLive = self->_playing
                && self->_playoutInitialized
                && self->_audioUnit != NULL
                && !self->_inputBusEnabled
                && self->_outputBusEnabled
                && !self->_recording
                && !self->_wantsRecording
                && self->_microphoneAuthorization == nil
                && microphoneGateClosed
                && self->_sessionActive
                && [self ownsCurrentSessionActivation]
                && [self sessionMatchesCurrentPolicy:session]
                && [self hasOutputRouteForSession:session];
#if DEBUG
            if (self->_debugRecoveryHarnessMode) {
                topologyIsLive = self->_playing
                    && self->_playoutInitialized
                    && !self->_inputBusEnabled
                    && self->_outputBusEnabled
                    && !self->_recording
                    && !self->_wantsRecording
                    && self->_microphoneAuthorization == nil
                    && microphoneGateClosed
                    && self->_sessionActive
                    && self->_debugOwnsSessionActivation
                    && [self sessionMatchesCurrentPolicy:nil]
                    && [self hasOutputRouteForSession:nil];
            }
#endif
            accepted = rebuilt
                && [self hostedCallModeIsAuthorized]
                && topologyIsLive;
            if (rebuilt && !accepted) {
                [self failAndRollbackWithCode:
                    ASIOSStereoPlayoutFailureMediaRouteInvariant
                                       status:kAudio_ParamError
                                      message:@"The hosted-call rebuild did not publish a live output-only topology."];
            }
            if (!accepted) {
                self->_recoveryRequired = self->_wantsPlayout;
                atomic_store_explicit(
                    &self->_lifecycle.recoveryRequired,
                    self->_recoveryRequired,
                    memory_order_relaxed
                );
                [self revokeHostedCallAuthorization];
            }
            self->_hostedCallRecoveryInProgressAuthorization = nil;
        }];
        [self publishHostedCallLifecycleState];
        if (!authorized || !attempted || !accepted) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
            if (authorization.isValid) {
                [authorization revoke];
            }
        }
    }];
}

- (ASIOSStereoPlayoutDiagnostics)diagnostics {
    AVAudioSession *session = [self currentAudioSession];
    BOOL ownsSessionActivation = [self ownsCurrentSessionActivation];
    BOOL sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_relaxed
    ) && ownsSessionActivation;
    ASIOSStereoPlayoutDiagnostics diagnostics = {0};
    BOOL hostedCallModeSnapshot = atomic_load_explicit(
        &_lifecycle.hostedCallMode,
        memory_order_relaxed
    );
    diagnostics.initialized = atomic_load_explicit(
        &_lifecycle.initialized,
        memory_order_relaxed
    );
    diagnostics.playoutInitialized = atomic_load_explicit(
        &_lifecycle.playoutInitialized,
        memory_order_relaxed
    );
    diagnostics.playing = atomic_load_explicit(&_lifecycle.playing, memory_order_relaxed);
    diagnostics.sessionActive = sessionActive;
    diagnostics.ownsSessionActivation = ownsSessionActivation;
    diagnostics.remoteIOCreated = atomic_load_explicit(
        &_lifecycle.remoteIOCreated,
        memory_order_relaxed
    );
    diagnostics.inputBusEnabled = atomic_load_explicit(
        &_lifecycle.inputBusEnabled,
        memory_order_relaxed
    );
    uint64_t captureRouteProofGenerationBefore =
        atomic_load_explicit(
            &_captureRouteProofGeneration,
            memory_order_acquire
        );
    BOOL liveCaptureRouteIsBuiltInMicrophone = NO;
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        liveCaptureRouteIsBuiltInMicrophone =
            _debugCaptureRouteIsBuiltInMicrophone;
    } else {
#endif
        // A nonzero proof generation is published only by the exact consumed built-in-mic
        // transaction or its fresh exact reopen. Do not resample a loose currentRoute boolean.
        liveCaptureRouteIsBuiltInMicrophone = YES;
#if DEBUG
    }
#endif
    diagnostics.outputBusEnabled = atomic_load_explicit(
        &_lifecycle.outputBusEnabled,
        memory_order_relaxed
    );
    diagnostics.recoveryRequired = atomic_load_explicit(
        &_lifecycle.recoveryRequired,
        memory_order_relaxed
    );
    diagnostics.explicitResumeRequired = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_relaxed
    );
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        BOOL hasActiveRecordedConfiguration =
            _debugHasRecordedAudioPolicyConfiguration && _sessionActive;
        diagnostics.categoryIsMediaPlayback =
            hasActiveRecordedConfiguration
            && [_debugLastConfiguredCategory
                isEqualToString:AVAudioSessionCategoryPlayback];
        diagnostics.categoryIsMediaPlayAndRecord =
            hasActiveRecordedConfiguration
            && [_debugLastConfiguredCategory
                isEqualToString:AVAudioSessionCategoryPlayAndRecord];
        diagnostics.modeIsDefault =
            hasActiveRecordedConfiguration
            && [_debugLastConfiguredMode
                isEqualToString:AVAudioSessionModeDefault];
        // These fields represent hardware route values in production. The deterministic harness
        // exposes the 48-kHz stereo client ASBD separately and therefore leaves them unset.
        diagnostics.sampleRate = 0;
        diagnostics.outputIOBufferDuration = 0;
        diagnostics.outputChannelCount = 0;
    } else {
#endif
        diagnostics.categoryIsMediaPlayback =
            [session.category isEqualToString:AVAudioSessionCategoryPlayback];
        diagnostics.categoryIsMediaPlayAndRecord =
            [session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord];
        diagnostics.modeIsDefault =
            [session.mode isEqualToString:AVAudioSessionModeDefault];
        diagnostics.sampleRate = session.sampleRate;
        diagnostics.outputIOBufferDuration = session.IOBufferDuration;
        diagnostics.outputChannelCount = session.outputNumberOfChannels;
#if DEBUG
    }
#endif
    diagnostics.audioUnitSubType = (uint32_t)atomic_load_explicit(
        &_lifecycle.audioUnitSubType,
        memory_order_relaxed
    );
    diagnostics.failureCode = (ASIOSStereoPlayoutFailureCode)atomic_load_explicit(
        &_lifecycle.failureCode,
        memory_order_relaxed
    );
    diagnostics.lastLifecycleStatus = (int32_t)atomic_load_explicit(
        &_lifecycle.lastLifecycleStatus,
        memory_order_relaxed
    );

    // Keep all callback-produced fields from one even publication epoch. In particular, a new
    // maximum gap can never be observed without the violation count written by that same callback.
    for (;;) {
        uint_fast64_t sequenceBefore = atomic_load_explicit(
            &_realtime.publicationSequence,
            memory_order_acquire
        );
        if ((sequenceBefore & 1) != 0) {
            continue;
        }
    diagnostics.playoutCallbackCount = atomic_load_explicit(
        &_realtime.callbackCount,
        memory_order_acquire
    );
    diagnostics.playoutFrameCount = atomic_load_explicit(
        &_realtime.frameCount,
        memory_order_relaxed
    );
    diagnostics.playoutFailureCount = atomic_load_explicit(
        &_realtime.failureCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMSampleCount = atomic_load_explicit(
        &_realtime.pcmSampleCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMNonzeroSampleCount = atomic_load_explicit(
        &_realtime.pcmNonzeroSampleCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMAbsoluteSampleSum = atomic_load_explicit(
        &_realtime.pcmAbsoluteSampleSum,
        memory_order_relaxed
    );
    diagnostics.playoutPCMLeftAbsoluteSampleSum = atomic_load_explicit(
        &_realtime.pcmLeftAbsoluteSampleSum,
        memory_order_relaxed
    );
    diagnostics.playoutPCMRightAbsoluteSampleSum = atomic_load_explicit(
        &_realtime.pcmRightAbsoluteSampleSum,
        memory_order_relaxed
    );
    diagnostics.playoutPCMStereoDifferenceAbsoluteSampleSum = atomic_load_explicit(
        &_realtime.pcmStereoDifferenceAbsoluteSampleSum,
        memory_order_relaxed
    );
    diagnostics.playoutPCMClippedSampleCount = atomic_load_explicit(
        &_realtime.pcmClippedSampleCount,
        memory_order_relaxed
    );
    diagnostics.playoutExplicitSilenceCallbackCount = atomic_load_explicit(
        &_realtime.explicitSilenceCallbackCount,
        memory_order_relaxed
    );
    diagnostics.playoutCallbackGapViolationCount = atomic_load_explicit(
        &_realtime.callbackGapViolationCount,
        memory_order_relaxed
    );
    diagnostics.playoutMaximumCallbackGapNanoseconds = atomic_load_explicit(
        &_realtime.maximumCallbackGapNanoseconds,
        memory_order_relaxed
    );
    diagnostics.playoutNearSilenceCallbackCount = atomic_load_explicit(
        &_realtime.nearSilenceCallbackCount,
        memory_order_relaxed
    );
    diagnostics.playoutCurrentConsecutiveNearSilenceFrameCount = atomic_load_explicit(
        &_realtime.currentConsecutiveNearSilenceFrameCount,
        memory_order_relaxed
    );
    diagnostics.playoutMaximumConsecutiveNearSilenceFrameCount = atomic_load_explicit(
        &_realtime.maximumConsecutiveNearSilenceFrameCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMLeftZeroCrossingCount = atomic_load_explicit(
        &_realtime.pcmLeftZeroCrossingCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMRightZeroCrossingCount = atomic_load_explicit(
        &_realtime.pcmRightZeroCrossingCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMEnvelopeTransitionCount = atomic_load_explicit(
        &_realtime.pcmEnvelopeTransitionCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMShapeAnomalyCallbackCount = atomic_load_explicit(
        &_realtime.pcmShapeAnomalyCallbackCount,
        memory_order_relaxed
    );
    diagnostics.playoutPCMBoundaryDiscontinuityCallbackCount = atomic_load_explicit(
        &_realtime.pcmBoundaryDiscontinuityCallbackCount,
        memory_order_relaxed
    );
    diagnostics.playoutLastCallbackMeanMagnitude = atomic_load_explicit(
        &_realtime.lastPCMCallbackMeanMagnitude,
        memory_order_relaxed
    );
    diagnostics.lastPlayoutFrameCount = atomic_load_explicit(
        &_realtime.lastFrameCount,
        memory_order_relaxed
    );
    diagnostics.lastPlayoutPeakMagnitude = atomic_load_explicit(
        &_realtime.lastPeakMagnitude,
        memory_order_relaxed
    );
    diagnostics.lastPlayoutStatus = atomic_load_explicit(
        &_realtime.lastStatus,
        memory_order_relaxed
    );
    diagnostics.microphoneDeviceGateClosedAndDrained =
        ASRealtimeGateIsClosedAndDrained(
            &_realtimeMicrophoneDeviceGate
        );
    diagnostics.microphoneAuthorizationGatePublished =
        atomic_load_explicit(
            &_realtimeMicrophoneAuthorizationGate,
            memory_order_acquire
        ) != 0;
    diagnostics.microphoneRecordingGeneration =
        atomic_load_explicit(
            &_realtimeMicrophoneRecordingGeneration,
            memory_order_acquire
        );
    diagnostics.approvedMicrophoneRecordingGeneration =
        atomic_load_explicit(
            &_realtimeApprovedMicrophoneRecordingGeneration,
            memory_order_acquire
        );
    diagnostics.microphoneRealtimeAdmissionCount =
        atomic_load_explicit(
            &_realtime.microphoneRealtimeAdmissionCount,
            memory_order_relaxed
        );
    diagnostics.microphoneDeliveryCallbackCount =
        atomic_load_explicit(
            &_realtime.microphoneDeliveryCallbackCount,
            memory_order_relaxed
        );
    diagnostics.microphoneDeliveredFrameCount =
        atomic_load_explicit(
            &_realtime.microphoneDeliveredFrameCount,
            memory_order_relaxed
        );

        uint_fast64_t sequenceAfter = atomic_load_explicit(
            &_realtime.publicationSequence,
            memory_order_acquire
        );
        if (sequenceBefore == sequenceAfter) {
            break;
        }
    }
    uint64_t captureRouteProofGenerationAfter =
        atomic_load_explicit(
            &_captureRouteProofGeneration,
            memory_order_acquire
        );
    diagnostics.captureRouteProofGeneration =
        captureRouteProofGenerationBefore != 0
            && captureRouteProofGenerationBefore
                == captureRouteProofGenerationAfter
        ? captureRouteProofGenerationAfter
        : 0;
    diagnostics.captureRouteIsBuiltInMicrophone =
        diagnostics.inputBusEnabled
        && diagnostics.captureRouteProofGeneration != 0
        && diagnostics.microphoneRecordingGeneration != 0
        && diagnostics.microphoneRecordingGeneration
            == diagnostics.approvedMicrophoneRecordingGeneration
        && liveCaptureRouteIsBuiltInMicrophone;
    diagnostics.unexpectedRecordingRequestCount = atomic_load_explicit(
        &_realtime.recordingRequestCount,
        memory_order_relaxed
    );
    diagnostics.recoveryRequestCount = atomic_load_explicit(
        &_realtime.recoveryRequestCount,
        memory_order_relaxed
    );
    diagnostics.recoveryAuthorizationRejectionCount = atomic_load_explicit(
        &_realtime.recoveryAuthorizationRejectionCount,
        memory_order_relaxed
    );
    diagnostics.recoveryRebuildCount = atomic_load_explicit(
        &_realtime.recoveryRebuildCount,
        memory_order_relaxed
    );
 #if DEBUG
    if (_debugRecoveryHarnessMode) {
        BOOL hasActiveRecordedConfiguration =
            _debugHasRecordedAudioPolicyConfiguration && _sessionActive;
        diagnostics.categoryOptionsAreEmpty =
            hasActiveRecordedConfiguration
            && _debugLastConfiguredCategoryOptions == 0;
        diagnostics.categoryOptionsAreIPhoneMicrophoneRouting =
            hasActiveRecordedConfiguration
            && _debugLastConfiguredCategoryOptions
                == ASIPhoneMicrophoneCategoryOptions();
        diagnostics.routeSharingPolicyIsDefault =
            hasActiveRecordedConfiguration
            && _debugLastConfiguredRouteSharingPolicy
                == AVAudioSessionRouteSharingPolicyDefault;
        diagnostics.categoryOptionsAreMixWithOthers =
            hasActiveRecordedConfiguration
            && _debugLastConfiguredCategoryOptions
                == AVAudioSessionCategoryOptionMixWithOthers;
    } else {
 #endif
        diagnostics.categoryOptionsAreEmpty = session.categoryOptions == 0;
        diagnostics.categoryOptionsAreIPhoneMicrophoneRouting =
            session.categoryOptions == ASIPhoneMicrophoneCategoryOptions();
        diagnostics.routeSharingPolicyIsDefault =
            session.routeSharingPolicy == AVAudioSessionRouteSharingPolicyDefault;
        diagnostics.categoryOptionsAreMixWithOthers =
            session.categoryOptions == AVAudioSessionCategoryOptionMixWithOthers;
 #if DEBUG
    }
 #endif
    diagnostics.hasOutputRoute = [self hasOutputRouteForSession:session];
    diagnostics.hostedCallMode = hostedCallModeSnapshot;
    diagnostics.hostedCallAuthorizationValid = atomic_load_explicit(
        &_lifecycle.hostedCallAuthorizationValid,
        memory_order_relaxed
    );
    diagnostics.hostedCallRecoveryPending = atomic_load_explicit(
        &_lifecycle.hostedCallRecoveryPending,
        memory_order_relaxed
    );
    diagnostics.hostedCallOrigin =
        (ASIOSHostedCallPlayoutOrigin)atomic_load_explicit(
            &_lifecycle.hostedCallOrigin,
            memory_order_relaxed
        );
    diagnostics.systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    diagnostics.hostedCallAuthorizationGeneration = atomic_load_explicit(
        &_lifecycle.hostedCallAuthorizationGeneration,
        memory_order_relaxed
    );
    return diagnostics;
}

- (void)clearCurrentMicrophoneRecordingGeneration {
    atomic_store_explicit(
        &_realtimeApprovedMicrophoneRecordingGeneration,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &_realtimeMicrophoneRecordingGeneration,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &_microphoneApprovalConsumedGeneration,
        0,
        memory_order_release
    );
}

- (uint64_t)installNextMicrophoneRecordingGeneration {
    _microphoneRecordingGenerationCounter += 1;
    if (_microphoneRecordingGenerationCounter == 0) {
        _microphoneRecordingGenerationCounter = 1;
    }

    uint64_t recordingGeneration =
        _microphoneRecordingGenerationCounter;
    atomic_store_explicit(
        &_realtimeApprovedMicrophoneRecordingGeneration,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &_microphoneApprovalConsumedGeneration,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &_realtimeMicrophoneRecordingGeneration,
        recordingGeneration,
        memory_order_release
    );
    return recordingGeneration;
}

- (uint64_t)publishNextCaptureRouteProofGeneration {
    _captureRouteProofGenerationCounter += 1;
    if (_captureRouteProofGenerationCounter == 0) {
        _captureRouteProofGenerationCounter = 1;
    }
    atomic_store_explicit(
        &_captureRouteProofGeneration,
        _captureRouteProofGenerationCounter,
        memory_order_release
    );
    return _captureRouteProofGenerationCounter;
}

- (BOOL)microphoneTopologyIsStagedAllowingDebugOverride:
    (BOOL)debugTopologyOverride {
    BOOL commonTopology =
        _initialized
        && _playing
        && _playoutInitialized
        && _inputBusEnabled
        && _outputBusEnabled
        && _recording
        && _wantsPlayout
        && _wantsRecording
        && !_interrupted
        && !_recoveryRequired
        && !_explicitResumeRequired
        && _sessionActive
        && _microphoneAuthorization != nil
        && ASMicrophoneAuthorizationIsValid(_microphoneAuthorization);
    if (debugTopologyOverride) {
        return commonTopology;
    }
    return commonTopology
        && _audioUnit != NULL
        && [self ownsCurrentSessionActivation]
        && _recordingSamples != NULL
        && _recordingSampleCapacity > 0
        && _recordedDataBlock != nil;
}

- (void)closeAndFenceRealtimeMicrophoneResources {
    atomic_store_explicit(
        &_captureRouteProofGeneration,
        0,
        memory_order_release
    );
    ASAssertRealtimeGateCanDrain(&_realtimeMicrophoneDeviceGate);
    BOOL didClose = ASCloseRealtimeGate(&_realtimeMicrophoneDeviceGate);
#if DEBUG
    if (didClose
        && !atomic_exchange_explicit(
            &_debugDeviceGateClosureSignaled,
            true,
            memory_order_acq_rel
        )) {
        dispatch_semaphore_signal(_debugDeviceGateClosureSemaphore);
    }
#else
    (void)didClose;
#endif
    ASDrainRealtimeGate(&_realtimeMicrophoneDeviceGate);
    atomic_store_explicit(
        &_realtimeMicrophoneAuthorizationGate,
        0,
        memory_order_release
    );
    atomic_store_explicit(
        &_realtimeApprovedMicrophoneRecordingGeneration,
        0,
        memory_order_release
    );
}

- (void)closeAndFenceRealtimePlayoutResources {
    ASAssertRealtimeGateCanDrain(&_realtimePlayoutDeviceGate);
    (void)ASCloseRealtimeGate(&_realtimePlayoutDeviceGate);
    ASDrainRealtimeGate(&_realtimePlayoutDeviceGate);
}

- (void)closeRealtimeRouteGatesWithoutDraining {
    // AVAudioSession delivers notifications on the posting thread. Close the
    // admission gates synchronously, but leave draining to the serialized
    // system-event rollback so this callback can never wait on itself.
    (void)ASCloseRealtimeGate(&_realtimePlayoutDeviceGate);
    (void)ASCloseRealtimeGate(&_realtimeMicrophoneDeviceGate);
    atomic_store_explicit(
        &_captureRouteProofGeneration,
        0,
        memory_order_release
    );
}

- (BOOL)publishFinalLiveMicrophoneResourcesWithAuthorization:
    (ASIOSMicrophoneAuthorization *)authorization
                                      debugTopologyOverride:(BOOL)debugTopologyOverride {
    uint64_t recordingGeneration =
        authorization.microphoneRecordingGeneration;
    uint64_t currentRecordingGeneration = atomic_load_explicit(
        &_realtimeMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    uint64_t approvedRecordingGeneration = atomic_load_explicit(
        &_realtimeApprovedMicrophoneRecordingGeneration,
        memory_order_acquire
    );
    uint64_t consumedRecordingGeneration = atomic_load_explicit(
        &_microphoneApprovalConsumedGeneration,
        memory_order_acquire
    );
    if (authorization == nil
        || recordingGeneration == 0
        || currentRecordingGeneration != recordingGeneration
        || approvedRecordingGeneration != 0
        || consumedRecordingGeneration != 0) {
        [self closeAndFenceRealtimeMicrophoneResources];
        return NO;
    }

    [self closeAndFenceRealtimeMicrophoneResources];

    BOOL allowDebugTopology = NO;
#if DEBUG
    allowDebugTopology = debugTopologyOverride;
#else
    (void)debugTopologyOverride;
#endif

    __attribute__((cleanup(ASReleaseUnfairLockScope)))
    ASUnfairLockScope microphonePublicationConfigurationScope = {
        .lock = NULL,
    };
    os_unfair_lock_lock(&ASSessionConfigurationLock);
    microphonePublicationConfigurationScope.lock =
        &ASSessionConfigurationLock;

    BOOL hasMicrophoneTopology = _inputBusEnabled || _recording;
    if (!allowDebugTopology && !hasMicrophoneTopology) {
        return YES;
    }
    if (authorization == nil) {
        return NO;
    }

    BOOL ownsSessionActivation =
        allowDebugTopology || [self ownsCurrentSessionActivation];
    BOOL topologyEligible =
        allowDebugTopology
        || (_initialized
            && _playing
            && _playoutInitialized
            && _audioUnit != NULL
            && _inputBusEnabled
            && _outputBusEnabled
            && _recording
            && _wantsPlayout
            && _wantsRecording
            && !_interrupted
            && !_recoveryRequired
            && !atomic_load_explicit(
                &_lifecycle.recoveryRequired,
                memory_order_acquire
            )
            && !_explicitResumeRequired
            && _sessionActive
            && ownsSessionActivation
            && _recordingSamples != NULL
            && _recordingSampleCapacity > 0
            && _recordedDataBlock != nil);
    if (!topologyEligible) {
        return NO;
    }

#if DEBUG
    _debugDeviceGateClosureSemaphore = dispatch_semaphore_create(0);
    atomic_store_explicit(
        &_debugDeviceGateClosureSignaled,
        false,
        memory_order_release
    );
#endif

    __block BOOL published = NO;
    __block uint64_t routeClosureTransactionIdentifier = 0;
    BOOL remainedValid = [authorization performWhileValid:^{
        uint64_t finalRouteValidationSequence = 0;
        uint64_t finalRouteTransactionIdentifier = 0;
        uint64_t finalRouteTransactionRevision = 0;
        if (!allowDebugTopology) {
            BOOL freshRouteIsExact = [self
                transitionExpectedMicrophoneRouteChangeForSession:
                    [self currentAudioSession]
                transactionIdentifier:0
                expectedState:ASExpectedMicrophoneRouteChangeStateConsumed
                nextState:ASExpectedMicrophoneRouteChangeStateConsumed
                requirePreparedRoute:YES
                validatedNotificationSequence:&finalRouteValidationSequence];
            if (!freshRouteIsExact) {
                return;
            }
            os_unfair_lock_lock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            BOOL finalValidationIsCurrent =
                self->_expectedMicrophoneRouteChangeState
                    == ASExpectedMicrophoneRouteChangeStateConsumed
                && self->_expectedMicrophoneRouteChangeTransactionIdentifier
                    != 0
                && self->_expectedMicrophoneRouteChangeMutationSequence != 0
                && self->_expectedMicrophoneRouteChangeNotificationInFlightCount
                    == 0
                && self->_routeChangeNotificationSequence
                    == finalRouteValidationSequence;
            if (finalValidationIsCurrent) {
                finalRouteTransactionIdentifier =
                    self->_expectedMicrophoneRouteChangeTransactionIdentifier;
                finalRouteTransactionRevision =
                    self->_expectedMicrophoneRouteChangeMutationSequence;
            }
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            if (!finalValidationIsCurrent) {
                return;
            }
        }

        uint64_t currentGeneration = atomic_load_explicit(
            &self->_realtimeMicrophoneRecordingGeneration,
            memory_order_acquire
        );
        uint64_t approvedGeneration = atomic_load_explicit(
            &self->_realtimeApprovedMicrophoneRecordingGeneration,
            memory_order_acquire
        );
        uint64_t consumedGeneration = atomic_load_explicit(
            &self->_microphoneApprovalConsumedGeneration,
            memory_order_acquire
        );
        BOOL topologyStillEligible =
            allowDebugTopology
            || (self->_initialized
                && self->_playing
                && self->_playoutInitialized
                && self->_audioUnit != NULL
                && self->_inputBusEnabled
                && self->_outputBusEnabled
                && self->_recording
                && self->_wantsPlayout
                && self->_wantsRecording
                && !self->_interrupted
                && !self->_recoveryRequired
                && !atomic_load_explicit(
                    &self->_lifecycle.recoveryRequired,
                    memory_order_acquire
                )
                && !self->_explicitResumeRequired
                && self->_sessionActive
                && ownsSessionActivation
                && self->_recordingSamples != NULL
                && self->_recordingSampleCapacity > 0
                && self->_recordedDataBlock != nil);
        if (authorization.microphoneRecordingGeneration
                != recordingGeneration
            || currentGeneration != recordingGeneration
            || approvedGeneration != 0
            || consumedGeneration != 0
            || self->_microphoneAuthorization != authorization
            || !topologyStillEligible) {
            return;
        }
        os_unfair_lock_lock(
            &self->_expectedMicrophoneRouteChangeLock
        );
        uint64_t activeConfigurationGeneration = atomic_load_explicit(
            &self->_activeAudioConfigurationGeneration,
            memory_order_acquire
        );
        uint64_t systemAudioGeneration = atomic_load_explicit(
            &self->_systemAudioGeneration,
            memory_order_acquire
        );
        uint64_t currentOwnershipToken = atomic_load_explicit(
            &ASCurrentSessionOwnershipTokenSnapshot,
            memory_order_acquire
        );
        BOOL sessionOwnershipStillExact = allowDebugTopology
            || ASBoundOwnershipTokenMatchesSnapshot(
                self->_expectedMicrophoneRouteChangeOwnershipToken,
                currentOwnershipToken
            );
        BOOL routeAndLifecycleStillAuthorizeMicrophone =
            allowDebugTopology
            || (ASFinalMicrophoneRouteValidationIsCurrent(
                    finalRouteTransactionIdentifier,
                    self->_expectedMicrophoneRouteChangeTransactionIdentifier,
                    finalRouteTransactionRevision,
                    self->_expectedMicrophoneRouteChangeMutationSequence,
                    finalRouteValidationSequence,
                    self->_routeChangeNotificationSequence,
                    self->_expectedMicrophoneRouteChangeNotificationInFlightCount,
                    self->_expectedMicrophoneRouteChangeState
                )
            && self->_expectedMicrophoneRouteChangeConfigurationGeneration
                != 0
            && self->_expectedMicrophoneRouteChangeConfigurationGeneration
                == activeConfigurationGeneration
            && self->_expectedMicrophoneRouteChangeSystemAudioGeneration
                != 0
            && self->_expectedMicrophoneRouteChangeSystemAudioGeneration
                == systemAudioGeneration
            && self->_expectedMicrophoneRouteChangeOwnershipToken != 0
            && self->_expectedMicrophoneRouteChangeOwnershipToken
                == currentOwnershipToken
            && sessionOwnershipStillExact
            && atomic_load_explicit(
                &self->_lifecycle.playing,
                memory_order_acquire
            )
            && atomic_load_explicit(
                &self->_lifecycle.sessionActive,
                memory_order_acquire
            )
            && !atomic_load_explicit(
                &self->_lifecycle.recoveryRequired,
                memory_order_acquire
            )
            && !atomic_load_explicit(
                &self->_lifecycle.explicitResumeRequired,
                memory_order_acquire
            ));
        if (!routeAndLifecycleStillAuthorizeMicrophone) {
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            return;
        }
        BOOL routeEvidenceOwnsDeviceGateClosure =
            ASRouteEvidenceOwnsDeviceGateClosure(
                self->_expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence,
                self->_expectedMicrophoneRouteChangeNotificationInFlightCount
            );
        if (!ASRealtimeGateIsClosedAndDrained(
                &self->_realtimeMicrophoneDeviceGate)) {
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            ASFailRealtimeGateInvariant();
        }
        if (atomic_load_explicit(
                &self->_realtimeMicrophoneAuthorizationGate,
                memory_order_acquire
            ) != 0) {
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            ASFailRealtimeGateInvariant();
        }

        atomic_store_explicit(
            &self->_realtimeMicrophoneAuthorizationGate,
            (unsigned long)(uintptr_t)&authorization->_realtimeGate,
            memory_order_release
        );
        atomic_store_explicit(
            &self->_realtimeApprovedMicrophoneRecordingGeneration,
            recordingGeneration,
            memory_order_release
        );
        atomic_store_explicit(
            &self->_microphoneApprovalConsumedGeneration,
            recordingGeneration,
            memory_order_release
        );
        BOOL debugCaptureRouteIsBuiltInMicrophone = NO;
#if DEBUG
        debugCaptureRouteIsBuiltInMicrophone =
            self->_debugCaptureRouteIsBuiltInMicrophone;
#endif
        if (!allowDebugTopology
            || debugCaptureRouteIsBuiltInMicrophone) {
            (void)[self publishNextCaptureRouteProofGeneration];
        }
        if (!routeEvidenceOwnsDeviceGateClosure) {
            ASResetClosedRealtimeGate(
                &self->_realtimeMicrophoneDeviceGate
            );
        } else if (ASShouldScheduleRouteGateClosureResolution(
                self->_expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence,
                self->_expectedMicrophoneRouteChangeNotificationInFlightCount,
                self->_expectedMicrophoneRouteChangeState,
                atomic_load_explicit(
                    &self->_lifecycle.playing,
                    memory_order_acquire
                )
            )) {
            routeClosureTransactionIdentifier =
                self->_expectedMicrophoneRouteChangeTransactionIdentifier;
        }
        os_unfair_lock_unlock(
            &self->_expectedMicrophoneRouteChangeLock
        );
        published = YES;
    }];
    BOOL approved = remainedValid && published;
    if (!approved) {
        [self closeAndFenceRealtimeMicrophoneResources];
    } else if (routeClosureTransactionIdentifier != 0) {
        [self
            scheduleExpectedMicrophoneRouteGateReopenForTransactionIdentifier:
                routeClosureTransactionIdentifier];
    }
    return approved;
}

- (AVAudioSession *)currentAudioSession {
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        return nil;
    }
#endif
    return AVAudioSession.sharedInstance;
}

- (uint64_t)advanceSystemAudioGeneration {
    [self clearExpectedMicrophoneRouteChange];
    uint64_t generation = atomic_fetch_add_explicit(
        &_systemAudioGeneration,
        1,
        memory_order_acq_rel
    ) + 1;
    if (generation == 0) {
        generation = atomic_fetch_add_explicit(
            &_systemAudioGeneration,
            1,
            memory_order_acq_rel
        ) + 1;
    }
    return generation;
}

- (BOOL)hasOutputRouteForSession:(AVAudioSession *)session {
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        return _debugHasOutputRouteOverride && _debugHasOutputRoute;
    }
    if (_debugHasOutputRouteOverride) {
        return _debugHasOutputRoute;
    }
#endif
    return session != nil
        && session.currentRoute.outputs.count > 0
        && session.outputNumberOfChannels > 0;
}

- (BOOL)hostedCallOriginIsAdmissible:
    (ASIOSHostedCallPlayoutOrigin)origin {
    switch (origin) {
        case ASIOSHostedCallPlayoutOriginInterruption:
            return !_interrupted;
        case ASIOSHostedCallPlayoutOriginStartupConnectedCall:
            return !_interrupted;
        case ASIOSHostedCallPlayoutOriginUnspecified:
            return NO;
    }
    return NO;
}

- (BOOL)hostedCallOwnershipMatchesAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
                                 policyIdentifier:(NSUUID *)policyIdentifier
                                        generation:(uint64_t)generation {
    uint64_t currentGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    return authorization != nil
        && policyIdentifier != nil
        && generation != 0
        && currentGeneration == generation
        && _hostedCallAuthorization == authorization
        && _hostedCallPolicyIdentifier != nil
        && [_hostedCallPolicyIdentifier isEqual:policyIdentifier]
        && _hostedCallAuthorizationGeneration == generation
        && [authorization.policyIdentifier isEqual:policyIdentifier]
        && authorization.systemAudioGeneration == generation
        && [self hostedCallModeIsAuthorized];
}

- (BOOL)hostedCallModeIsAuthorized {
    ASIOSHostedCallPlayoutAuthorization *authorization =
        _hostedCallAuthorization;
    uint64_t currentGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    return currentGeneration != 0
        && authorization != nil
        && authorization.isValid
        && authorization.origin != ASIOSHostedCallPlayoutOriginUnspecified
        && [self hostedCallOriginIsAdmissible:authorization.origin]
        && _hostedCallPolicyIdentifier != nil
        && [_hostedCallPolicyIdentifier isEqual:authorization.policyIdentifier]
        && _hostedCallAuthorizationGeneration == currentGeneration
        && authorization.systemAudioGeneration == currentGeneration;
}

- (void)publishHostedCallLifecycleState {
    ASIOSHostedCallPlayoutAuthorization *authorization =
        _hostedCallAuthorization;
    uint64_t currentGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    BOOL authorizationOwnsCurrentPolicy = currentGeneration != 0
        && authorization != nil
        && authorization.isValid
        && authorization.origin != ASIOSHostedCallPlayoutOriginUnspecified
        && [self hostedCallOriginIsAdmissible:authorization.origin]
        && _hostedCallPolicyIdentifier != nil
        && [_hostedCallPolicyIdentifier isEqual:authorization.policyIdentifier]
        && _hostedCallAuthorizationGeneration == currentGeneration
        && authorization.systemAudioGeneration == currentGeneration;
    BOOL recoveryPending = authorizationOwnsCurrentPolicy
        && authorization.isRecoveryPending;
    atomic_store_explicit(
        &_lifecycle.hostedCallMode,
        authorizationOwnsCurrentPolicy,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &_lifecycle.hostedCallAuthorizationValid,
        authorizationOwnsCurrentPolicy,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &_lifecycle.hostedCallRecoveryPending,
        recoveryPending,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &_lifecycle.hostedCallOrigin,
        authorizationOwnsCurrentPolicy
            ? authorization.origin
            : ASIOSHostedCallPlayoutOriginUnspecified,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &_lifecycle.hostedCallAuthorizationGeneration,
        authorizationOwnsCurrentPolicy ? _hostedCallAuthorizationGeneration : 0,
        memory_order_relaxed
    );
}

- (void)retireMicrophoneAuthorizationForHostedCall {
    [self closeAndFenceRealtimeMicrophoneResources];
    __attribute__((objc_precise_lifetime))
    ASIOSMicrophoneAuthorization *retiringAuthorization =
        _microphoneAuthorization;
    _microphoneAuthorization = nil;
    _wantsRecording = NO;
    _recording = NO;
    [retiringAuthorization revoke];
}

- (void)revokeHostedCallAuthorization {
    __attribute__((objc_precise_lifetime))
    ASIOSHostedCallPlayoutAuthorization *authorization =
        _hostedCallAuthorization;
    _hostedCallAuthorization = nil;
    _hostedCallPolicyIdentifier = nil;
    _hostedCallAuthorizationGeneration = 0;
    [self publishHostedCallLifecycleState];
    if (authorization == nil) {
        return;
    }

    if (_hostedCallRecoveryInProgressAuthorization == authorization) {
        [authorization invalidateWhilePerforming];
        return;
    }

    [authorization clearRevocationHandler];
    [authorization revoke];
}

- (void)remainQuiescentAfterHostedCallOwnershipLossWithMessage:
    (NSString *)message {
    [self retireMicrophoneAuthorizationForHostedCall];
    if (_inputBusEnabled) {
        [self.delegate notifyAudioInputInterrupted];
    }
    if (_audioUnit != NULL || _playing) {
        [self.delegate notifyAudioOutputInterrupted];
    }

    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    _recoveryRequired = YES;
    atomic_store_explicit(
        &_lifecycle.recoveryRequired,
        true,
        memory_order_relaxed
    );

    NSMutableString *detail = [message mutableCopy];
    if (teardownStatus != noErr) {
        [detail appendFormat:@" RemoteIO teardown also failed (%d).", (int)teardownStatus];
    }
    if (!deactivated) {
        [detail appendFormat:
            @" Audio-session deactivation also failed: %@.",
            deactivationError.localizedDescription ?: @"unknown error"];
    }
    if (_wantsPlayout || teardownStatus != noErr || !deactivated) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                         status:(teardownStatus != noErr
                             ? (int32_t)teardownStatus
                             : (int32_t)deactivationError.code)
                        message:detail];
    }
}

- (void)hostedCallAuthorizationDidRevoke:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
                             policyIdentifier:(NSUUID *)policyIdentifier
                                    generation:(uint64_t)generation {
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }

    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchSync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil
            || !self->_initialized
            || self->_hostedCallAuthorization != authorization
            || self->_hostedCallAuthorizationGeneration != generation
            || self->_hostedCallPolicyIdentifier == nil
            || ![self->_hostedCallPolicyIdentifier
                isEqual:policyIdentifier]) {
            return;
        }

        [self advanceSystemAudioGeneration];
        [self revokeHostedCallAuthorization];
        [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
            @"Hosted-call policy was synchronously revoked; native audio remains quiescent until fresh application recovery."];
    }];
}

- (BOOL)applyAudioPolicyConfiguration:
    (ASAudioPolicyConfiguration)configuration
                              toSession:(AVAudioSession *)session
                                  error:(NSError **)error {
    AVAudioSessionCategory category =
        ASCategoryForAudioPolicyConfiguration(configuration);
#if DEBUG
    [self debugRecordAudioPolicyConfiguration:configuration];
    if (_debugRecoveryHarnessMode) {
        if (error != NULL) {
            *error = nil;
        }
        return YES;
    }
#endif
    if (session == nil) {
        return NO;
    }
    return [session setCategory:category
                          mode:AVAudioSessionModeDefault
            routeSharingPolicy:configuration.routeSharingPolicy
                       options:configuration.categoryOptions
                         error:error];
}

- (BOOL)sessionMatchesCurrentPolicy:(AVAudioSession *)session {
    BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
    BOOL microphoneEnabled = [self microphoneShouldBeActive];
    if (hostedCallMode && microphoneEnabled) {
        return NO;
    }

    ASAudioPolicyConfiguration configuration =
        ASMakeAudioPolicyConfiguration(
            hostedCallMode,
            microphoneEnabled,
            _streamFormat
        );
    AVAudioSessionCategory category =
        ASCategoryForAudioPolicyConfiguration(configuration);

#if DEBUG
    if (_debugRecoveryHarnessMode) {
        return _debugHasRecordedAudioPolicyConfiguration
            && [_debugLastConfiguredCategory isEqualToString:category]
            && [_debugLastConfiguredMode
                isEqualToString:AVAudioSessionModeDefault]
            && _debugLastConfiguredRouteSharingPolicy
                == configuration.routeSharingPolicy
            && _debugLastConfiguredCategoryOptions
                == configuration.categoryOptions
            && _debugLastConfiguredInputBusEnabled
                == configuration.inputBusEnabled
            && _debugLastConfiguredOutputBusEnabled
                == configuration.outputBusEnabled
            && ASAudioStreamBasicDescriptionsEqual(
                _debugLastConfiguredOutputStreamFormat,
                configuration.outputStreamFormat
            );
    }
#endif
    if (session == nil) {
        return NO;
    }

    return [session.category isEqualToString:category]
        && [session.mode isEqualToString:AVAudioSessionModeDefault]
        && session.categoryOptions == configuration.categoryOptions
        && session.routeSharingPolicy == configuration.routeSharingPolicy;
}

- (ASHostedCallRecoveryReadiness)
    hostedCallRecoveryReadinessForAuthorization:
        (ASIOSHostedCallPlayoutAuthorization *)authorization
                    expectedSystemAudioGeneration:(uint64_t)expectedGeneration {
    uint64_t currentGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    uint64_t authorizationGeneration = authorization.systemAudioGeneration;
    BOOL exactInstalledPolicy = expectedGeneration != 0
        && expectedGeneration == currentGeneration
        && authorization.isValid
        && authorization.origin
            == ASIOSHostedCallPlayoutOriginInterruption
        && !authorization.isRecoveryPending
        && _hostedCallAuthorization == authorization
        && _hostedCallPolicyIdentifier != nil
        && [_hostedCallPolicyIdentifier
            isEqual:authorization.policyIdentifier]
        && _hostedCallAuthorizationGeneration == currentGeneration
        && authorizationGeneration == currentGeneration
        && [self hostedCallModeIsAuthorized];
    if (exactInstalledPolicy) {
        return ASHostedCallRecoveryReadinessCoalesced;
    }

    if (!authorization.isValid
        || !authorization.isRecoveryPending
        || authorization.origin
            != ASIOSHostedCallPlayoutOriginInterruption
        || expectedGeneration == 0
        || expectedGeneration != currentGeneration
        || (authorizationGeneration != 0
            && authorizationGeneration != expectedGeneration)
        || authorization.policyIdentifier == nil
        || !_initialized
        || _isRebuilding
        || _explicitResumeRequired
        || _hostedCallAuthorization != nil) {
        return ASHostedCallRecoveryReadinessRejected;
    }

    AVAudioSession *session = [self currentAudioSession];
    BOOL ownsSessionActivation = [self ownsCurrentSessionActivation];
    BOOL healthyPlayout = !_interrupted
        && !_recoveryRequired
        && !_explicitResumeRequired
        && _playing
        && _playoutInitialized
        && _audioUnit != NULL
        && _outputBusEnabled
        && _sessionActive
        && ownsSessionActivation
        && [self sessionMatchesCurrentPolicy:session]
        && [self hasOutputRouteForSession:session];
#if DEBUG
    if (_debugRecoveryHarnessMode
        && _debugHealthyPlayoutForTesting
        && _sessionActive
        && _playing
        && _playoutInitialized
        && _outputBusEnabled
        && [self ownsCurrentSessionActivation]
        && [self sessionMatchesCurrentPolicy:session]
        && [self hasOutputRouteForSession:session]) {
        healthyPlayout = YES;
    }
#endif
    if (healthyPlayout) {
        return ASHostedCallRecoveryReadinessAwaitingFailClose;
    }

    BOOL microphoneGateIsClosed =
        ASRealtimeGateIsClosedAndDrained(&_realtimeMicrophoneDeviceGate)
        && atomic_load_explicit(
            &_realtimeMicrophoneAuthorizationGate,
            memory_order_acquire
        ) == 0;
    BOOL quiescent = !_sessionActive
        && !_playing
        && !_playoutInitialized
        && _audioUnit == NULL
        && !_recording
        && !_inputBusEnabled
        && !_outputBusEnabled
        && _recordingSamples == NULL
        && _recordingSampleCapacity == 0
        && !ownsSessionActivation
        && microphoneGateIsClosed;
    if (!quiescent) {
        return ASHostedCallRecoveryReadinessRejected;
    }
    if (_interrupted) {
        return ASHostedCallRecoveryReadinessAwaitingFailClose;
    }
    if (!_wantsPlayout) {
        return ASHostedCallRecoveryReadinessRejected;
    }
    if (!_recoveryRequired) {
        return ASHostedCallRecoveryReadinessRejected;
    }
    return ASHostedCallRecoveryReadinessReady;
}

- (BOOL)configureSessionAndCreateRemoteIO {
    [self closeAndFenceRealtimePlayoutResources];
    [self closeAndFenceRealtimeMicrophoneResources];
    [self clearCurrentMicrophoneRecordingGeneration];
    NSError *error = nil;
    AVAudioSession *session = [self currentAudioSession];
    __attribute__((cleanup(ASReleaseUnfairLockScope)))
    ASUnfairLockScope sessionConfigurationScope = {
        .lock = NULL,
    };
    uint64_t configurationGeneration = 0;
    uint64_t configurationOwnershipToken = 0;
#if DEBUG
    BOOL usesDeterministicConfigurationBoundary = _debugRecoveryHarnessMode;
#else
    BOOL usesDeterministicConfigurationBoundary = NO;
#endif
    if (session == nil && !usesDeterministicConfigurationBoundary) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureSessionConfiguration
                               status:kAudio_ParamError
                              message:@"No native audio session is available for RemoteIO configuration."];
        return NO;
    }

    ASIOSHostedCallPlayoutAuthorization *expectedHostedAuthorization =
        _hostedCallAuthorization;
    NSUUID *expectedHostedPolicyIdentifier =
        [_hostedCallPolicyIdentifier copy];
    uint64_t expectedHostedGeneration =
        _hostedCallAuthorizationGeneration;
    BOOL hasHostedCallOwnership =
        expectedHostedAuthorization != nil
        || expectedHostedPolicyIdentifier != nil
        || expectedHostedGeneration != 0;
    BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
    if (hasHostedCallOwnership && !hostedCallMode) {
        _recoveryRequired = YES;
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            true,
            memory_order_relaxed
        );
        [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                         status:noErr
                        message:@"A revoked or inadmissible hosted-call policy cannot configure ordinary native audio."];
        return NO;
    }

    BOOL microphoneAuthorizationIsLive =
        ASMicrophoneAuthorizationIsValid(_microphoneAuthorization);
    if (hostedCallMode
        && (microphoneAuthorizationIsLive
            || _wantsRecording
            || _recording
            || _inputBusEnabled)) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureSessionConfiguration
                               status:kAudio_ParamError
                              message:@"Hosted-call playout must remain output-only."];
        return NO;
    }

    BOOL microphoneEnabled = [self microphoneShouldBeActive];
    ASAudioPolicyConfiguration configuration =
        ASMakeAudioPolicyConfiguration(
            hostedCallMode,
            microphoneEnabled,
            _streamFormat
        );
    if (!usesDeterministicConfigurationBoundary) {
        os_unfair_lock_lock(&ASSessionConfigurationLock);
        sessionConfigurationScope.lock = &ASSessionConfigurationLock;
        _audioConfigurationGenerationCounter += 1;
        if (_audioConfigurationGenerationCounter == 0) {
            _audioConfigurationGenerationCounter = 1;
        }
        configurationGeneration = _audioConfigurationGenerationCounter;
        atomic_store_explicit(
            &_activeAudioConfigurationGeneration,
            configurationGeneration,
            memory_order_release
        );
        [self clearExpectedMicrophoneRouteChange];
        if (!hostedCallMode
            && ![self
                armExpectedMicrophoneRouteChangeForSession:session
                inputRequired:microphoneEnabled
                configurationGeneration:configurationGeneration]) {
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseArm
                session:session
                expectedTransactionIdentifier:0
                requiredNotificationSequence:0];
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionConfiguration
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"The iPhone microphone audio-session transaction could not be armed. %@",
                                      routeSnapshot]];
            return NO;
        }
    }
    if (![self applyAudioPolicyConfiguration:configuration
                                   toSession:session
                                       error:&error]) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSessionConfiguration
                               status:(int32_t)error.code
                              message:[NSString stringWithFormat:
                                  @"Media audio-session configuration failed: %@",
                                  error.localizedDescription ?: @"unknown error"]];
        return NO;
    }
    if (hostedCallMode
        && ![self
            hostedCallOwnershipMatchesAuthorization:
                expectedHostedAuthorization
            policyIdentifier:expectedHostedPolicyIdentifier
            generation:expectedHostedGeneration]) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureSessionConfiguration
                               status:kAudio_ParamError
                              message:@"Hosted-call ownership changed during audio-session configuration."];
        return NO;
    }

#if DEBUG
    if (_debugRecoveryHarnessMode) {
        if (![self sessionMatchesCurrentPolicy:nil]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionConfiguration
                                   status:kAudio_ParamError
                                  message:@"The deterministic boundary did not retain the production audio-policy inputs."];
            return NO;
        }
        if (hostedCallMode && _debugFailNextHostedCallActivation) {
            _debugFailNextHostedCallActivation = NO;
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionActivation
                                   status:kAudio_ParamError
                                  message:@"Deterministic hosted-call activation failure."];
            return NO;
        }
        if (![self hasOutputRouteForSession:nil]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:@"The deterministic configuration boundary has no output route."];
            return NO;
        }
        return YES;
    }
#endif

    if (hostedCallMode) {
        (void)[session setPreferredSampleRate:ASSampleRate error:nil];
        (void)[session setPreferredIOBufferDuration:ASIOBufferDuration error:nil];
    } else {
        if (![session setPreferredSampleRate:ASSampleRate error:&error]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred sample-rate request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        }
        if (![session
                setPreferredIOBufferDuration:ASIOBufferDuration
                                       error:&error]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred IO-buffer-duration request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        }
    }
    error = nil;
    ASOwnedSessionConfigurationFailure sessionFailure =
        [self activateOwnedSessionAndApplyRoutePreferences:session
                                            hostedCallMode:hostedCallMode
                                          microphoneEnabled:microphoneEnabled
                                      configurationGeneration:
                                          configurationGeneration
                                                     error:&error];
    switch (sessionFailure) {
        case ASOwnedSessionConfigurationFailureNone:
            break;
        case ASOwnedSessionConfigurationFailureActivation:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionActivation
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Media playback audio-session activation failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailureBuiltInMicrophoneUnavailable:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"The active route exposes no built-in iPhone microphone. %@",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailurePreferredInputRequest:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred built-in iPhone microphone request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailurePreferredInputDidNotConverge:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"The built-in iPhone microphone route did not converge before RemoteIO creation. %@",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailureSessionInactive:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionActivation
                                   status:kAudio_ParamError
                                  message:@"Channel preferences were rejected because this peer does not own an active audio session."];
            return NO;
        case ASOwnedSessionConfigurationFailureOutputUnavailable:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"The active route cannot provide stereo output before RemoteIO creation. %@",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailureOutputRequest:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred stereo-output request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailureInputUnavailable:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMediaRouteInvariant
                                   status:kAudio_ParamError
                                  message:[NSString stringWithFormat:
                                      @"The active route cannot provide mono iPhone microphone input before RemoteIO creation. %@",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        case ASOwnedSessionConfigurationFailureInputRequest:
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred mono-input request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
    }
    configurationOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    if (configurationOwnershipToken == 0
        || ![self
            sessionOwnershipMatchesToken:configurationOwnershipToken]
        || atomic_load_explicit(
            &_activeAudioConfigurationGeneration,
            memory_order_acquire
        ) != configurationGeneration) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureSessionActivation
                               status:kAudio_ParamError
                              message:@"Audio-session ownership changed before route validation."];
        return NO;
    }
    if (hostedCallMode
        && ![self
            hostedCallOwnershipMatchesAuthorization:
                expectedHostedAuthorization
            policyIdentifier:expectedHostedPolicyIdentifier
            generation:expectedHostedGeneration]) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureSessionActivation
                               status:kAudio_ParamError
                               message:@"Hosted-call ownership changed during audio-session activation."];
        return NO;
    }

    BOOL hasOutputRoute = [self hasOutputRouteForSession:session];
    BOOL hardwareRouteIsAcceptable = hostedCallMode
        ? (session.sampleRate > 0
            && session.IOBufferDuration > 0
            && hasOutputRoute)
        : (fabs(session.sampleRate - ASSampleRate) < 0.5
            && session.IOBufferDuration > 0
            && session.outputNumberOfChannels >= ASOutputChannelCount
            && (!microphoneEnabled
                || session.inputNumberOfChannels >= ASInputChannelCount));
    if (![self sessionMatchesCurrentPolicy:session]
        || !hardwareRouteIsAcceptable) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureMediaRouteInvariant
                               status:kAudio_ParamError
                              message:[NSString stringWithFormat:
                                  @"The active route cannot satisfy the %@ output policy "
                                   @"(route=%@). %@",
                                  hostedCallMode ? @"hosted-call" : @"48 kHz stereo",
                                  hasOutputRoute ? @"present" : @"missing",
                                  ASAudioSessionDiagnosticDescription(session)]];
        return NO;
    }

    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (component == NULL) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureAudioComponentUnavailable
                               status:kAudio_UnimplementedError
                              message:@"RemoteIO audio component is unavailable."];
        return NO;
    }
    OSStatus status = AudioComponentInstanceNew(component, &_audioUnit);
    if (status != noErr || _audioUnit == NULL) {
        _audioUnit = NULL;
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureAudioUnitCreation
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"RemoteIO creation failed (%d).",
                                  (int)status]];
        return NO;
    }
    _audioUnitRunning = NO;
    _audioUnitSubType = description.componentSubType;
    atomic_store_explicit(&_lifecycle.remoteIOCreated, true, memory_order_relaxed);
    atomic_store_explicit(
        &_lifecycle.audioUnitSubType,
        description.componentSubType,
        memory_order_relaxed
    );

    UInt32 inputPolicy = microphoneEnabled ? 1 : 0;
    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &inputPolicy,
        sizeof(inputPolicy)
    );
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureMicrophoneBusDisable
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to configure RemoteIO microphone bus (%d).",
                                  (int)status]];
        return NO;
    }
    UInt32 enabled = 1;
    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &enabled,
        sizeof(enabled)
    );
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSpeakerBusEnable
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to enable RemoteIO speaker bus (%d).",
                                  (int)status]];
        return NO;
    }

    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &_streamFormat,
        sizeof(_streamFormat)
    );
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureStreamFormat
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to set RemoteIO stereo format (%d).",
                                  (int)status]];
        return NO;
    }

    AURenderCallbackStruct callback = {
        .inputProc = ASRemoteIORender,
        .inputProcRefCon = (__bridge void *)self,
    };
    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callback,
        sizeof(callback)
    );
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureRenderCallback
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to install RemoteIO render callback (%d).",
                                  (int)status]];
        return NO;
    }

    if (microphoneEnabled) {
        status = AudioUnitSetProperty(
            _audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &_inputStreamFormat,
            sizeof(_inputStreamFormat)
        );
        if (status != noErr) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneStreamFormat
                                   status:(int32_t)status
                                  message:[NSString stringWithFormat:
                                      @"Failed to set RemoteIO mono input format (%d).",
                                      (int)status]];
            return NO;
        }

        UInt32 maximumFrames = 0;
        UInt32 maximumFramesSize = sizeof(maximumFrames);
        status = AudioUnitGetProperty(
            _audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            &maximumFramesSize
        );
        if (status != noErr || maximumFrames == 0) {
            maximumFrames = 4096;
        }
        _recordingSamples = calloc(maximumFrames, sizeof(int16_t));
        if (_recordingSamples == NULL) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneBufferAllocation
                                   status:kAudio_MemFullError
                                  message:@"Failed to allocate the fixed RemoteIO microphone buffer."];
            return NO;
        }
        _recordingSampleCapacity = maximumFrames;

        AURenderCallbackStruct inputCallback = {
            .inputProc = ASRemoteIOInput,
            .inputProcRefCon = (__bridge void *)self,
        };
        status = AudioUnitSetProperty(
            _audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            1,
            &inputCallback,
            sizeof(inputCallback)
        );
        if (status != noErr) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneInputCallback
                                   status:(int32_t)status
                                  message:[NSString stringWithFormat:
                                      @"Failed to install RemoteIO microphone callback (%d).",
                                      (int)status]];
            return NO;
        }
    }

    UInt32 propertySize = sizeof(UInt32);
    UInt32 inputEnabled = 1;
    UInt32 outputEnabled = 0;
    AudioUnitGetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &inputEnabled,
        &propertySize
    );
    propertySize = sizeof(UInt32);
    AudioUnitGetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &outputEnabled,
        &propertySize
    );
    _inputBusEnabled = inputEnabled != 0;
    _outputBusEnabled = outputEnabled != 0;
    atomic_store_explicit(
        &_lifecycle.inputBusEnabled,
        _inputBusEnabled,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &_lifecycle.outputBusEnabled,
        _outputBusEnabled,
        memory_order_relaxed
    );
    if (_inputBusEnabled != microphoneEnabled || !_outputBusEnabled) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureBusValidation
                               status:kAudio_ParamError
                              message:@"RemoteIO did not preserve the requested duplex bus policy."];
        return NO;
    }
    _recording = microphoneEnabled;

    AudioStreamBasicDescription actualFormat = {0};
    UInt32 formatSize = sizeof(actualFormat);
    status = AudioUnitGetProperty(
        _audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &actualFormat,
        &formatSize
    );
    if (status != noErr
        || actualFormat.mFormatID != kAudioFormatLinearPCM
        || actualFormat.mSampleRate != ASSampleRate
        || actualFormat.mChannelsPerFrame != ASOutputChannelCount
        || actualFormat.mBitsPerChannel != 16
        || (actualFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        OSStatus formatStatus = status == noErr ? kAudio_ParamError : status;
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailurePCMValidation
                               status:(int32_t)formatStatus
                              message:[NSString stringWithFormat:
                                  @"RemoteIO did not preserve 48 kHz interleaved Int16 stereo (%d).",
                                  (int)formatStatus]];
        return NO;
    }

    if (microphoneEnabled) {
        AudioStreamBasicDescription actualInputFormat = {0};
        UInt32 inputFormatSize = sizeof(actualInputFormat);
        status = AudioUnitGetProperty(
            _audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &actualInputFormat,
            &inputFormatSize
        );
        if (status != noErr
            || actualInputFormat.mFormatID != kAudioFormatLinearPCM
            || actualInputFormat.mSampleRate != ASSampleRate
            || actualInputFormat.mChannelsPerFrame != ASInputChannelCount
            || actualInputFormat.mBitsPerChannel != 16
            || (actualInputFormat.mFormatFlags
                & kAudioFormatFlagIsNonInterleaved) != 0) {
            OSStatus inputStatus = status == noErr
                ? kAudio_ParamError
                : status;
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureMicrophoneStreamFormat
                                   status:(int32_t)inputStatus
                                  message:@"RemoteIO did not preserve 48 kHz mono Int16 microphone PCM."];
            return NO;
        }
    }

    status = AudioUnitInitialize(_audioUnit);
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureAudioUnitInitialization
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to initialize RemoteIO (%d).",
                                  (int)status]];
        return NO;
    }
    if (![self sessionOwnershipMatchesToken:configurationOwnershipToken]
        || atomic_load_explicit(
            &_activeAudioConfigurationGeneration,
            memory_order_acquire
        ) != configurationGeneration
        || ![self sessionMatchesCurrentPolicy:session]
        || ![self hasOutputRouteForSession:session]
        || (microphoneEnabled
            && (!ASAudioSessionUsesBuiltInMicrophone(session)
                || session.inputNumberOfChannels
                    < ASInputChannelCount))
        || (!hostedCallMode
            && session.outputNumberOfChannels
                < ASOutputChannelCount)) {
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureMediaRouteInvariant
                               status:kAudio_ParamError
                              message:[NSString stringWithFormat:
                                  @"Audio-session ownership or route changed before RemoteIO publication. %@",
                                  ASAudioSessionDiagnosticDescription(session)]];
        return NO;
    }
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    if (!hostedCallMode
        && ![self
            prepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
                session
            configurationGeneration:configurationGeneration
            ownershipToken:configurationOwnershipToken]) {
        NSString *routeSnapshot = [self
            routeTransactionFailureSnapshotForPhase:
                ASRouteTransactionDiagnosticPhasePrepare
            session:session
            expectedTransactionIdentifier:0
            requiredNotificationSequence:0];
        [self failAndRollbackWithCode:
            ASIOSStereoPlayoutFailureMediaRouteInvariant
                               status:kAudio_ParamError
                              message:[NSString stringWithFormat:
                                  @"The audio-session route transaction did not reach a provenance-bound state before RemoteIO start preparation. %@",
                                  routeSnapshot]];
        return NO;
    }
    _playoutInitialized = YES;
    atomic_store_explicit(&_lifecycle.playoutInitialized, true, memory_order_relaxed);
    [self clearLifecycleFailure];
    return YES;
}

- (ASOwnedSessionConfigurationFailure)
    activateOwnedSessionAndApplyRoutePreferences:
        (AVAudioSession *)session
                             hostedCallMode:(BOOL)hostedCallMode
                           microphoneEnabled:(BOOL)microphoneEnabled
                       configurationGeneration:
                           (uint64_t)configurationGeneration
                                      error:(NSError **)error {
    NSError *transactionError = nil;
    ASOwnedSessionConfigurationFailure failure =
        ASOwnedSessionConfigurationFailureNone;
    uint64_t ownershipToken = 0;
    AVAudioSessionPortDescription *targetBuiltInMicrophone = nil;
    BOOL preferredInputMutationIssued = NO;

    os_unfair_lock_lock(&ASSessionOwnershipLock);
    BOOL activated = [session setActive:YES error:&transactionError];
    if (activated) {
        ASNextSessionOwnershipToken += 1;
        if (ASNextSessionOwnershipToken == 0) {
            ASNextSessionOwnershipToken = 1;
        }
        _sessionOwnershipToken = ASNextSessionOwnershipToken;
        ASCurrentSessionOwnershipToken = _sessionOwnershipToken;
        ownershipToken = _sessionOwnershipToken;
        atomic_store_explicit(
            &ASCurrentSessionOwnershipTokenSnapshot,
            ownershipToken,
            memory_order_release
        );
    }
    os_unfair_lock_unlock(&ASSessionOwnershipLock);

    if (!activated) {
        failure = ASOwnedSessionConfigurationFailureActivation;
    } else {
        _sessionActive = YES;
        atomic_store_explicit(
            &_lifecycle.sessionActive,
            true,
            memory_order_release
        );
    }

    if (failure == ASOwnedSessionConfigurationFailureNone
        && !hostedCallMode
        && !microphoneEnabled
        && ![self
            bindExpectedMicrophoneRouteChangeToTargetInput:nil
            ownershipToken:ownershipToken
            requirePreferredInput:NO
            configurationGeneration:configurationGeneration]) {
        failure = ASOwnedSessionConfigurationFailureSessionInactive;
    }

    if (failure == ASOwnedSessionConfigurationFailureNone
        && !hostedCallMode
        && microphoneEnabled) {
        for (AVAudioSessionPortDescription *input in session.availableInputs) {
            if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                targetBuiltInMicrophone = input;
                break;
            }
        }
        if (targetBuiltInMicrophone == nil
            || targetBuiltInMicrophone.UID.length == 0) {
            failure =
                ASOwnedSessionConfigurationFailureBuiltInMicrophoneUnavailable;
        } else {
            BOOL currentInputIsExactTarget =
                session.currentRoute.inputs.count == 1
                && ASAudioSessionPortMatches(
                    session.currentRoute.inputs.firstObject,
                    AVAudioSessionPortBuiltInMic,
                    targetBuiltInMicrophone.UID
                );
            preferredInputMutationIssued = !currentInputIsExactTarget;
            if (![self
                bindExpectedMicrophoneRouteChangeToTargetInput:
                    targetBuiltInMicrophone
                ownershipToken:ownershipToken
                requirePreferredInput:preferredInputMutationIssued
                configurationGeneration:configurationGeneration]) {
                failure =
                    ASOwnedSessionConfigurationFailurePreferredInputDidNotConverge;
            } else if (preferredInputMutationIssued) {
                os_unfair_lock_lock(&ASSessionOwnershipLock);
                BOOL stillOwnsSession =
                    ownershipToken != 0
                    && _sessionOwnershipToken == ownershipToken
                    && ASCurrentSessionOwnershipToken == ownershipToken;
                BOOL selected = stillOwnsSession
                    && [session setPreferredInput:targetBuiltInMicrophone
                                            error:&transactionError];
                os_unfair_lock_unlock(&ASSessionOwnershipLock);
                if (!stillOwnsSession) {
                    failure =
                        ASOwnedSessionConfigurationFailureSessionInactive;
                } else if (!selected) {
                    failure =
                        ASOwnedSessionConfigurationFailurePreferredInputRequest;
                }
            }
            if (failure == ASOwnedSessionConfigurationFailureNone
                && ![self
                    waitForExpectedMicrophoneConvergenceForSession:session
                    targetInput:targetBuiltInMicrophone
                    requirePreferredInput:preferredInputMutationIssued
                    requireExactChannels:NO
                    configurationGeneration:configurationGeneration
                    ownershipToken:ownershipToken]) {
                failure =
                    ASOwnedSessionConfigurationFailurePreferredInputDidNotConverge;
            }
        }
    }

    if (failure == ASOwnedSessionConfigurationFailureNone
        && !hostedCallMode) {
        os_unfair_lock_lock(&ASSessionOwnershipLock);
        BOOL stillOwnsSession =
            ownershipToken != 0
            && _sessionOwnershipToken == ownershipToken
            && ASCurrentSessionOwnershipToken == ownershipToken;
        ASActiveChannelPreferenceFailure channelFailure =
            ASApplyActiveChannelPreferences(
                (id<ASAudioSessionChannelPreferenceConfiguring>)session,
                stillOwnsSession,
                microphoneEnabled,
                &transactionError
            );
        BOOL ownershipSurvivedMutation =
            stillOwnsSession
            && _sessionOwnershipToken == ownershipToken
            && ASCurrentSessionOwnershipToken == ownershipToken;
        os_unfair_lock_unlock(&ASSessionOwnershipLock);
        failure = ownershipSurvivedMutation
            ? ASOwnedSessionFailureForChannels(channelFailure)
            : ASOwnedSessionConfigurationFailureSessionInactive;
    }

    if (failure == ASOwnedSessionConfigurationFailureNone
        && !hostedCallMode) {
        if (![self
            waitForExpectedMicrophoneConvergenceForSession:session
            targetInput:targetBuiltInMicrophone
            requirePreferredInput:preferredInputMutationIssued
            requireExactChannels:YES
            configurationGeneration:configurationGeneration
            ownershipToken:ownershipToken]) {
            failure = session.outputNumberOfChannels < ASOutputChannelCount
                ? ASOwnedSessionConfigurationFailureOutputUnavailable
                : (microphoneEnabled
                    && session.inputNumberOfChannels < ASInputChannelCount
                    ? ASOwnedSessionConfigurationFailureInputUnavailable
                    : ASOwnedSessionConfigurationFailurePreferredInputDidNotConverge);
        }
    }

    if (failure != ASOwnedSessionConfigurationFailureNone) {
        [self clearExpectedMicrophoneRouteChange];
        os_unfair_lock_lock(&ASSessionOwnershipLock);
        if (ownershipToken != 0
            && _sessionOwnershipToken == ownershipToken
            && ASCurrentSessionOwnershipToken == ownershipToken) {
            (void)[session setActive:NO error:nil];
            ASCurrentSessionOwnershipToken = 0;
            atomic_store_explicit(
                &ASCurrentSessionOwnershipTokenSnapshot,
                0,
                memory_order_release
            );
        }
        _sessionOwnershipToken = 0;
        os_unfair_lock_unlock(&ASSessionOwnershipLock);
        _sessionActive = NO;
        atomic_store_explicit(
            &_lifecycle.sessionActive,
            false,
            memory_order_release
        );
    }
    if (error != NULL) {
        *error = transactionError;
    }
    return failure;
}

- (BOOL)deactivateOwnedSessionWithError:(NSError **)error {
    [self clearExpectedMicrophoneRouteChange];
    atomic_store_explicit(
        &_activeAudioConfigurationGeneration,
        0,
        memory_order_release
    );
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        _debugOwnsSessionActivation = NO;
        _sessionOwnershipToken = 0;
        _sessionActive = NO;
        atomic_store_explicit(
            &_lifecycle.sessionActive,
            false,
            memory_order_relaxed
        );
        if (error != NULL) {
            *error = nil;
        }
        return YES;
    }
#endif

    NSError *deactivationError = nil;
    BOOL deactivated = YES;
    os_unfair_lock_lock(&ASSessionOwnershipLock);
    uint64_t token = _sessionOwnershipToken;
    if (token != 0 && ASCurrentSessionOwnershipToken == token) {
        deactivated = [AVAudioSession.sharedInstance
            setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:&deactivationError];
        // This retiring lease must never remain authoritative. A later successful activation will
        // take a fresh token even if native deactivation reported an error.
        ASCurrentSessionOwnershipToken = 0;
        atomic_store_explicit(
            &ASCurrentSessionOwnershipTokenSnapshot,
            0,
            memory_order_release
        );
    }
    _sessionOwnershipToken = 0;
    os_unfair_lock_unlock(&ASSessionOwnershipLock);

    _sessionActive = NO;
    atomic_store_explicit(&_lifecycle.sessionActive, false, memory_order_relaxed);
    if (error != NULL) {
        *error = deactivationError;
    }
    return deactivated;
}

- (BOOL)ownsCurrentSessionActivation {
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        return _debugOwnsSessionActivation;
    }
#endif

    os_unfair_lock_lock(&ASSessionOwnershipLock);
    BOOL owns = _sessionOwnershipToken != 0
        && ASCurrentSessionOwnershipToken == _sessionOwnershipToken;
    os_unfair_lock_unlock(&ASSessionOwnershipLock);
    return owns;
}

- (BOOL)sessionOwnershipMatchesToken:(uint64_t)ownershipToken {
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        return ownershipToken != 0
            && _debugOwnsSessionActivation
            && _sessionOwnershipToken == ownershipToken;
    }
#endif
    os_unfair_lock_lock(&ASSessionOwnershipLock);
    BOOL matches = ownershipToken != 0
        && _sessionOwnershipToken == ownershipToken
        && ASCurrentSessionOwnershipToken == ownershipToken;
    os_unfair_lock_unlock(&ASSessionOwnershipLock);
    return matches;
}

- (NSString *)routeTransactionFailureSnapshotForPhase:
    (ASRouteTransactionDiagnosticPhase)phase
                                               session:
                                                   (AVAudioSession *)session
                         expectedTransactionIdentifier:
                             (uint64_t)expectedTransactionIdentifier
                           requiredNotificationSequence:
                               (uint64_t)requiredNotificationSequence {
    if (phase == ASRouteTransactionDiagnosticPhaseObservationRejection) {
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        NSString *immutableRejectionSnapshot =
            [_expectedMicrophoneRouteChangeRejectionSnapshot copy];
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (immutableRejectionSnapshot.length > 0) {
            return immutableRejectionSnapshot;
        }
    }

    ASExpectedMicrophoneRouteChangeState requiredState =
        ASExpectedMicrophoneRouteChangeStatePending;
    BOOL requireOwnership = NO;
    BOOL requirePreparedRoute = NO;
    BOOL requirePolicy = NO;
    BOOL requireStartSettlement = NO;
    BOOL requirePlaying = NO;
    BOOL requireRouteClosure = NO;
    BOOL requirePlayoutGateDrained = NO;
    switch (phase) {
        case ASRouteTransactionDiagnosticPhaseArm:
            break;
        case ASRouteTransactionDiagnosticPhasePrepare:
            requiredState = ASExpectedMicrophoneRouteChangeStatePrepared;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseBeginStart:
            requiredState = ASExpectedMicrophoneRouteChangeStatePrepared;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseNativeStart:
            requiredState = ASExpectedMicrophoneRouteChangeStateStarting;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseMarkStartCompleted:
            requiredState = ASExpectedMicrophoneRouteChangeStateStarting;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseCommit:
            requiredState = ASExpectedMicrophoneRouteChangeStateStarting;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            requireStartSettlement = YES;
            break;
        case ASRouteTransactionDiagnosticPhasePublish:
            requiredState = ASExpectedMicrophoneRouteChangeStateConsumed;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            requirePlayoutGateDrained = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseObservationRejection:
            requiredState = ASExpectedMicrophoneRouteChangeStateRejected;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            break;
        case ASRouteTransactionDiagnosticPhaseFreshReopen:
            requiredState = ASExpectedMicrophoneRouteChangeStateConsumed;
            requireOwnership = YES;
            requirePreparedRoute = YES;
            requirePolicy = YES;
            requirePlaying = YES;
            requireRouteClosure = YES;
            break;
    }

    ASRouteTransactionFailureSnapshot *snapshot =
        [[ASRouteTransactionFailureSnapshot alloc] init];
    snapshot.phase = ASRouteTransactionDiagnosticPhaseDescription(phase);
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    uint64_t deadline = 0;
    ASRemoteIOStartSettlement startSettlement = {0};

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    AVAudioSession *currentSession = session ?: [self currentAudioSession];
    AVAudioSessionRouteDescription *route = currentSession.currentRoute;
    AVAudioSessionPortDescription *currentInput = route.inputs.firstObject;
    AVAudioSessionPortDescription *preferredInput = currentSession.preferredInput;
    ASExpectedMicrophoneRouteChangeState state =
        _expectedMicrophoneRouteChangeState;
    snapshot.state =
        ASExpectedMicrophoneRouteChangeStateDescription(state);
    snapshot.transactionIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifier;
    snapshot.expectedTransactionIdentifier = expectedTransactionIdentifier;
    snapshot.notificationSequence = _routeChangeNotificationSequence;
    snapshot.observerSequenceBaseline =
        _expectedMicrophoneRouteChangeObserverSequenceBaseline;
    snapshot.requiredNotificationSequence = requiredNotificationSequence;
    snapshot.notificationInFlightCount =
        _expectedMicrophoneRouteChangeNotificationInFlightCount;
    snapshot.boundConfigurationGeneration =
        _expectedMicrophoneRouteChangeConfigurationGeneration;
    snapshot.currentConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    snapshot.boundSystemAudioGeneration =
        _expectedMicrophoneRouteChangeSystemAudioGeneration;
    snapshot.currentSystemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    snapshot.boundOwnershipToken =
        _expectedMicrophoneRouteChangeOwnershipToken;
    snapshot.currentOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    snapshot.sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_acquire
    );
    snapshot.recoveryRequired = atomic_load_explicit(
        &_lifecycle.recoveryRequired,
        memory_order_acquire
    );
    snapshot.explicitResumeRequired = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_acquire
    );
    snapshot.playing = atomic_load_explicit(
        &_lifecycle.playing,
        memory_order_acquire
    );
    snapshot.routeClosureRecorded =
        _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence;
    snapshot.inputRequired = _expectedMicrophoneRouteChangeInputRequired;
    snapshot.preferredInputRequired =
        _expectedMicrophoneRouteChangeRequiresPreferredInput;
    snapshot.playoutGateClosedAndDrained =
        ASRealtimeGateIsClosedAndDrained(&_realtimePlayoutDeviceGate);
    snapshot.microphoneGateClosedAndDrained =
        ASRealtimeGateIsClosedAndDrained(&_realtimeMicrophoneDeviceGate);
    snapshot.boundCursorFingerprint =
        [_expectedMicrophoneRouteChangeTransitionCursorFingerprint copy];
    snapshot.boundPreparedRouteFingerprint =
        [_expectedMicrophoneRouteChangeConvergedRouteFingerprint copy];
    snapshot.boundOutputFingerprint =
        [_expectedMicrophoneRouteChangeOutputFingerprint copy];
    snapshot.boundTargetInputIdentifier =
        [_expectedMicrophoneRouteChangeTargetInputIdentifier copy];
    snapshot.currentRouteFingerprint =
        ASAudioSessionRouteFingerprint(route);
    snapshot.currentOutputFingerprint =
        ASAudioSessionPortsFingerprint(route.outputs);
    snapshot.currentInputType = [currentInput.portType copy];
    snapshot.currentInputIdentifier = [currentInput.UID copy];
    snapshot.preferredInputType = [preferredInput.portType copy];
    snapshot.preferredInputIdentifier = [preferredInput.UID copy];
    snapshot.category = [currentSession.category copy];
    snapshot.mode = [currentSession.mode copy];
    snapshot.categoryOptions = currentSession.categoryOptions;
    snapshot.sharingPolicy = currentSession.routeSharingPolicy;
    snapshot.inputCount = route.inputs.count;
    snapshot.outputCount = route.outputs.count;
    snapshot.inputChannels = currentSession.inputNumberOfChannels;
    snapshot.outputChannels = currentSession.outputNumberOfChannels;
    deadline = _expectedMicrophoneRouteChangeDeadlineNanoseconds;
    startSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

    BOOL transactionIdentifierIsExact =
        snapshot.transactionIdentifier != 0
        && (expectedTransactionIdentifier == 0
            || snapshot.transactionIdentifier
                == expectedTransactionIdentifier);
    if (!transactionIdentifierIsExact) {
        [failed addObject:@"transactionIdentifier"];
    }
    if (state != requiredState) {
        [failed addObject:@"phaseState"];
    }
    if (snapshot.notificationInFlightCount != 0) {
        [failed addObject:@"notificationsDrained"];
    }
    if (requiredNotificationSequence != 0
        && !ASValidatedRouteNotificationSequenceIsCurrent(
            requiredNotificationSequence,
            snapshot.notificationSequence
        )) {
        [failed addObject:@"notificationSequence"];
    }
    if (snapshot.boundConfigurationGeneration == 0
        || snapshot.boundConfigurationGeneration
            != snapshot.currentConfigurationGeneration) {
        [failed addObject:@"configurationGeneration"];
    }
    if (snapshot.boundSystemAudioGeneration == 0
        || snapshot.boundSystemAudioGeneration
            != snapshot.currentSystemAudioGeneration) {
        [failed addObject:@"systemAudioGeneration"];
    }
    if (requireOwnership
        && (snapshot.boundOwnershipToken == 0
            || snapshot.boundOwnershipToken
                != snapshot.currentOwnershipToken)) {
        [failed addObject:@"ownershipToken"];
    }
    if (requireOwnership && !snapshot.sessionActive) {
        [failed addObject:@"sessionActive"];
    }
    if (requireOwnership && snapshot.recoveryRequired) {
        [failed addObject:@"recoveryClear"];
    }
    if (requireOwnership && snapshot.explicitResumeRequired) {
        [failed addObject:@"explicitResumeClear"];
    }
    uint64_t now = ASMonotonicNanoseconds();
    if (deadline == 0 || now == 0 || now > deadline) {
        [failed addObject:@"deadline"];
    }
    if (snapshot.boundCursorFingerprint.length == 0
        || ![snapshot.boundCursorFingerprint
            isEqualToString:snapshot.currentRouteFingerprint]) {
        [failed addObject:@"routeCursor"];
    }
    if (requirePreparedRoute
        && (snapshot.boundPreparedRouteFingerprint.length == 0
            || ![snapshot.boundPreparedRouteFingerprint
                isEqualToString:snapshot.currentRouteFingerprint])) {
        [failed addObject:@"preparedRoute"];
    }
    if (requirePreparedRoute
        && (snapshot.boundOutputFingerprint.length == 0
            || ![snapshot.boundOutputFingerprint
                isEqualToString:snapshot.currentOutputFingerprint])) {
        [failed addObject:@"outputFingerprint"];
    }
    if (requirePreparedRoute && snapshot.outputCount == 0) {
        [failed addObject:@"outputAvailable"];
    }
    if (requirePreparedRoute
        && snapshot.outputChannels != ASOutputChannelCount) {
        [failed addObject:@"outputChannels"];
    }
    if (requirePreparedRoute
        && snapshot.inputRequired
        && snapshot.inputChannels != ASInputChannelCount) {
        [failed addObject:@"inputChannels"];
    }
    BOOL currentInputIsExact = !snapshot.inputRequired
        || (snapshot.inputCount == 1
            && [snapshot.currentInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [snapshot.currentInputIdentifier
                isEqualToString:snapshot.boundTargetInputIdentifier]);
    if (requirePreparedRoute && !currentInputIsExact) {
        [failed addObject:@"currentInput"];
    }
    BOOL preferredInputIsExact = !snapshot.preferredInputRequired
        || ([snapshot.preferredInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [snapshot.preferredInputIdentifier
                isEqualToString:snapshot.boundTargetInputIdentifier]);
    if (requirePreparedRoute && !preferredInputIsExact) {
        [failed addObject:@"preferredInput"];
    }
    BOOL policyIsExact = snapshot.inputRequired
        ? ([snapshot.category
                isEqualToString:AVAudioSessionCategoryPlayAndRecord]
            && snapshot.categoryOptions
                == ASIPhoneMicrophoneCategoryOptions())
        : ([snapshot.category
                isEqualToString:AVAudioSessionCategoryPlayback]
            && snapshot.categoryOptions == 0);
    if (requirePolicy && !policyIsExact) {
        [failed addObject:@"audioPolicy"];
    }
    if (requirePolicy
        && ![snapshot.mode isEqualToString:AVAudioSessionModeDefault]) {
        [failed addObject:@"mode"];
    }
    if (requirePolicy
        && snapshot.sharingPolicy
            != AVAudioSessionRouteSharingPolicyDefault) {
        [failed addObject:@"sharingPolicy"];
    }
    if (requireStartSettlement
        && !ASRemoteIOStartSettlementIsCurrent(
            startSettlement,
            snapshot.transactionIdentifier,
            now
        )) {
        [failed addObject:@"startSettlement"];
    }
    if (requirePlaying && !snapshot.playing) {
        [failed addObject:@"playing"];
    }
    if (requireRouteClosure && !snapshot.routeClosureRecorded) {
        [failed addObject:@"routeClosure"];
    }
    if (requirePlayoutGateDrained
        && !snapshot.playoutGateClosedAndDrained) {
        [failed addObject:@"playoutGateDrained"];
    }
    snapshot.failedPredicates = failed;
    return ASRouteTransactionFailureSnapshotDescription(snapshot);
}

- (BOOL)armExpectedMicrophoneRouteChangeForSession:
    (AVAudioSession *)session
                                      inputRequired:(BOOL)inputRequired
                         configurationGeneration:
                             (uint64_t)configurationGeneration {
    if (session == nil || configurationGeneration == 0) {
        return NO;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    // Sample the route while holding the same ingress lock that assigns the
    // observer sequence. A notification that was already admitted is fully
    // represented in this fingerprint; one that arrives afterward receives
    // a sequence strictly beyond the baseline and is processed by this
    // transaction. There is no pre-route/post-baseline blind interval.
    AVAudioSessionRouteDescription *initialRoute = session.currentRoute;
    NSString *initialRouteFingerprint =
        ASAudioSessionRouteFingerprint(initialRoute);
    NSString *initialOutputFingerprint =
        ASAudioSessionPortsFingerprint(initialRoute.outputs);
    uint64_t now = ASMonotonicNanoseconds();
    uint64_t systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    uint64_t activeConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    uint64_t deadline =
        now > UINT64_MAX
                - ASExpectedMicrophoneRouteChangeLifetimeNanoseconds
        ? UINT64_MAX
        : now + ASExpectedMicrophoneRouteChangeLifetimeNanoseconds;
    BOOL canArm =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateNone
        && configurationGeneration == activeConfigurationGeneration
        && systemAudioGeneration != 0
        && now != 0
        && initialRouteFingerprint.length > 0
        && initialRoute.outputs.count > 0
        && initialOutputFingerprint.length > 0;
    if (canArm) {
        _expectedMicrophoneRouteChangeTransactionIdentifierCounter += 1;
        if (_expectedMicrophoneRouteChangeTransactionIdentifierCounter == 0) {
            _expectedMicrophoneRouteChangeTransactionIdentifierCounter = 1;
        }
        _expectedMicrophoneRouteChangeTransactionIdentifier =
            _expectedMicrophoneRouteChangeTransactionIdentifierCounter;
        _expectedMicrophoneRouteChangeState =
            ASExpectedMicrophoneRouteChangeStatePending;
        _expectedMicrophoneRouteChangeConfigurationGeneration =
            configurationGeneration;
        _expectedMicrophoneRouteChangeOwnershipToken = 0;
        _expectedMicrophoneRouteChangeSystemAudioGeneration =
            systemAudioGeneration;
        _expectedMicrophoneRouteChangeObserverSequenceBaseline =
            _routeChangeNotificationSequence;
        _expectedMicrophoneRouteChangeDeadlineNanoseconds = deadline;
        ASRetireRemoteIOStartSettlement(
            &_expectedMicrophoneRouteChangeStartSettlement
        );
        _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence = NO;
        _expectedMicrophoneRouteChangeTransitionCursorFingerprint =
            [initialRouteFingerprint copy];
        _expectedMicrophoneRouteChangeConvergedRouteFingerprint = nil;
        _expectedMicrophoneRouteChangeOutputFingerprint =
            [initialOutputFingerprint copy];
        _expectedMicrophoneRouteChangeTargetInputIdentifier = nil;
        _expectedMicrophoneRouteChangeInputRequired = inputRequired;
        _expectedMicrophoneRouteChangeRequiresPreferredInput = NO;
        _expectedMicrophoneRouteChangeSemaphore = semaphore;
        _expectedMicrophoneRouteChangeRejectionSnapshot = nil;
        _expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
        _expectedMicrophoneRouteChangeMutationSequence += 1;
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return canArm;
}

- (BOOL)bindExpectedMicrophoneRouteChangeToTargetInput:
    (AVAudioSessionPortDescription *)targetInput
                                              ownershipToken:
                                                  (uint64_t)ownershipToken
                                      requirePreferredInput:
                                          (BOOL)requirePreferredInput
                                      configurationGeneration:
                                          (uint64_t)configurationGeneration {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t retryDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;
    for (;;) {
        if ([self
            tryBindExpectedMicrophoneRouteChangeToTargetInput:targetInput
            ownershipToken:ownershipToken
            requirePreferredInput:requirePreferredInput
            configurationGeneration:configurationGeneration]) {
            return YES;
        }

        uint64_t now = ASMonotonicNanoseconds();
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL transactionCanRetry =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStatePending
            && now != 0
            && now < retryDeadline;
        dispatch_semaphore_t semaphore = transactionCanRetry
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!transactionCanRetry || semaphore == nil) {
            return NO;
        }
        uint64_t slice = MIN(
            retryDeadline - now,
            (uint64_t)10000000
        );
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)tryBindExpectedMicrophoneRouteChangeToTargetInput:
    (AVAudioSessionPortDescription *)targetInput
                                                 ownershipToken:
                                                     (uint64_t)ownershipToken
                                         requirePreferredInput:
                                             (BOOL)requirePreferredInput
                                         configurationGeneration:
                                             (uint64_t)configurationGeneration {
    if (![self
        waitForExpectedMicrophoneRouteChangeNotificationsToDrainInState:
            ASExpectedMicrophoneRouteChangeStatePending]) {
        return NO;
    }
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    uint64_t transactionRevision =
        _expectedMicrophoneRouteChangeMutationSequence;
    BOOL mayBind =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        && transactionRevision != 0
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (!mayBind) {
        return NO;
    }

    NSString *targetType = [targetInput.portType copy];
    NSString *targetIdentifier = [targetInput.UID copy];
    uint64_t now = ASMonotonicNanoseconds();
    uint64_t systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    uint64_t activeConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    uint64_t currentOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    BOOL sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_acquire
    );

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL inputRequired = _expectedMicrophoneRouteChangeInputRequired;
    BOOL targetIsValid = inputRequired
        ? (targetIdentifier.length > 0
            && [targetType isEqualToString:AVAudioSessionPortBuiltInMic])
        : targetIdentifier.length == 0;
    BOOL bound =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        && _expectedMicrophoneRouteChangeMutationSequence
            == transactionRevision
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeConfigurationGeneration
            == configurationGeneration
        && _expectedMicrophoneRouteChangeOwnershipToken == 0
        && _expectedMicrophoneRouteChangeSystemAudioGeneration
            == systemAudioGeneration
        && configurationGeneration == activeConfigurationGeneration
        && ownershipToken != 0
        && ownershipToken == currentOwnershipToken
        && sessionActive
        && now != 0
        && now <= _expectedMicrophoneRouteChangeDeadlineNanoseconds
        && targetIsValid;
    if (bound) {
        _expectedMicrophoneRouteChangeOwnershipToken = ownershipToken;
        _expectedMicrophoneRouteChangeTargetInputIdentifier =
            [targetIdentifier copy];
        _expectedMicrophoneRouteChangeRequiresPreferredInput =
            requirePreferredInput;
        _expectedMicrophoneRouteChangeMutationSequence += 1;
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return bound;
}

- (BOOL)waitForExpectedMicrophoneConvergenceForSession:
    (AVAudioSession *)session
                                                targetInput:
                                                    (AVAudioSessionPortDescription *)targetInput
                                     requirePreferredInput:
                                         (BOOL)requirePreferredInput
                                          requireExactChannels:
                                              (BOOL)requireExactChannels
                                configurationGeneration:
                                    (uint64_t)configurationGeneration
                                             ownershipToken:
                                                 (uint64_t)ownershipToken {
    NSString *targetIdentifier = [targetInput.UID copy];
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t waitDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;

    for (;;) {
        AVAudioSessionRouteDescription *route = session.currentRoute;
        NSString *currentRouteFingerprint =
            ASAudioSessionRouteFingerprint(route);
        NSString *currentOutputFingerprint =
            ASAudioSessionPortsFingerprint(route.outputs);
        AVAudioSessionPortDescription *currentInput =
            route.inputs.firstObject;
        AVAudioSessionPortDescription *preferredInput =
            session.preferredInput;
        BOOL targetRequired = targetIdentifier.length > 0;
        BOOL targetIsCurrent = !targetRequired
            || (route.inputs.count == 1
                && ASAudioSessionPortMatches(
                    currentInput,
                    AVAudioSessionPortBuiltInMic,
                    targetIdentifier
                ));
        BOOL targetIsPreferred = !requirePreferredInput
            || ASAudioSessionPortMatches(
                preferredInput,
                AVAudioSessionPortBuiltInMic,
                targetIdentifier
            );
        BOOL channelsAreExact = !requireExactChannels
            || (session.outputNumberOfChannels == ASOutputChannelCount
                && (!targetRequired
                    || session.inputNumberOfChannels
                        == ASInputChannelCount));
        BOOL outputPresent = route.outputs.count > 0;
        BOOL ownsSession = [self
            sessionOwnershipMatchesToken:ownershipToken];
        uint64_t activeConfigurationGeneration = atomic_load_explicit(
            &_activeAudioConfigurationGeneration,
            memory_order_acquire
        );
        uint64_t systemAudioGeneration = atomic_load_explicit(
            &_systemAudioGeneration,
            memory_order_acquire
        );
        uint64_t now = ASMonotonicNanoseconds();

        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL targetMatches =
            (_expectedMicrophoneRouteChangeTargetInputIdentifier == nil
                && targetIdentifier == nil)
            || [_expectedMicrophoneRouteChangeTargetInputIdentifier
                isEqualToString:targetIdentifier];
        BOOL transactionIsLive =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStatePending
            && _expectedMicrophoneRouteChangeConfigurationGeneration
                == configurationGeneration
            && _expectedMicrophoneRouteChangeOwnershipToken
                == ownershipToken
            && _expectedMicrophoneRouteChangeSystemAudioGeneration
                == systemAudioGeneration
            && configurationGeneration == activeConfigurationGeneration
            && targetMatches
            && ownsSession
            && now != 0
            && now <= _expectedMicrophoneRouteChangeDeadlineNanoseconds;
        BOOL routeWasObserved =
            currentRouteFingerprint.length > 0
            && [_expectedMicrophoneRouteChangeTransitionCursorFingerprint
                isEqualToString:currentRouteFingerprint];
        BOOL outputIsPinned =
            currentOutputFingerprint.length > 0
            && [_expectedMicrophoneRouteChangeOutputFingerprint
                isEqualToString:currentOutputFingerprint];
        BOOL converged = transactionIsLive
            && routeWasObserved
            && outputIsPinned
            && targetIsCurrent
            && targetIsPreferred
            && channelsAreExact
            && outputPresent;
        dispatch_semaphore_t semaphore = transactionIsLive
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);

        if (converged) {
            return YES;
        }
        if (!transactionIsLive || now >= waitDeadline || semaphore == nil) {
            return NO;
        }
        uint64_t remaining = waitDeadline - now;
        uint64_t slice = MIN(remaining, (uint64_t)10000000);
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)prepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
    (AVAudioSession *)session
                                  configurationGeneration:
                                      (uint64_t)configurationGeneration
                                               ownershipToken:
                                                   (uint64_t)ownershipToken {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t retryDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;
    for (;;) {
        if ([self
            tryPrepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
                session
            configurationGeneration:configurationGeneration
            ownershipToken:ownershipToken]) {
            return YES;
        }

        uint64_t now = ASMonotonicNanoseconds();
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL transactionCanRetry =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStatePending
            && now != 0
            && now < retryDeadline;
        dispatch_semaphore_t semaphore = transactionCanRetry
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!transactionCanRetry || semaphore == nil) {
            return NO;
        }
        uint64_t slice = MIN(
            retryDeadline - now,
            (uint64_t)10000000
        );
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)tryPrepareExpectedMicrophoneRouteChangeForAudioUnitStartForSession:
    (AVAudioSession *)session
                                     configurationGeneration:
                                         (uint64_t)configurationGeneration
                                                  ownershipToken:
                                                      (uint64_t)ownershipToken {
    if (![self
        waitForExpectedMicrophoneRouteChangeNotificationsToDrainInState:
            ASExpectedMicrophoneRouteChangeStatePending]) {
        return NO;
    }
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    uint64_t transactionRevision =
        _expectedMicrophoneRouteChangeMutationSequence;
    BOOL maySample =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        && transactionRevision != 0
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (!maySample) {
        return NO;
    }

    AVAudioSessionRouteDescription *route = session.currentRoute;
    AVAudioSessionPortDescription *currentInput = route.inputs.firstObject;
    AVAudioSessionPortDescription *preferredInput = session.preferredInput;
    NSString *currentInputType = [currentInput.portType copy];
    NSString *currentInputIdentifier = [currentInput.UID copy];
    NSString *preferredInputType = [preferredInput.portType copy];
    NSString *preferredInputIdentifier = [preferredInput.UID copy];
    NSString *currentRouteFingerprint =
        ASAudioSessionRouteFingerprint(route);
    NSString *currentOutputFingerprint =
        ASAudioSessionPortsFingerprint(route.outputs);
    NSString *category = [session.category copy];
    NSString *mode = [session.mode copy];
    AVAudioSessionCategoryOptions options = session.categoryOptions;
    AVAudioSessionRouteSharingPolicy sharingPolicy =
        session.routeSharingPolicy;
    NSUInteger inputCount = route.inputs.count;
    NSUInteger outputCount = route.outputs.count;
    NSInteger inputChannels = session.inputNumberOfChannels;
    NSInteger outputChannels = session.outputNumberOfChannels;
    BOOL ownsSession = [self sessionOwnershipMatchesToken:ownershipToken];
    uint64_t now = ASMonotonicNanoseconds();
    uint64_t systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    uint64_t activeConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    BOOL sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_acquire
    );
    BOOL recoveryRequired = atomic_load_explicit(
        &_lifecycle.recoveryRequired,
        memory_order_acquire
    );
    BOOL explicitResumeRequired = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_acquire
    );

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL inputRequired = _expectedMicrophoneRouteChangeInputRequired;
    BOOL targetIsCurrent = !inputRequired
        || (inputCount == 1
            && [currentInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [currentInputIdentifier isEqualToString:
                _expectedMicrophoneRouteChangeTargetInputIdentifier]);
    BOOL targetIsPreferred =
        !_expectedMicrophoneRouteChangeRequiresPreferredInput
        || ([preferredInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [preferredInputIdentifier isEqualToString:
                _expectedMicrophoneRouteChangeTargetInputIdentifier]);
    BOOL policyIsExact = inputRequired
        ? ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
            && options == ASIPhoneMicrophoneCategoryOptions())
        : ([category isEqualToString:AVAudioSessionCategoryPlayback]
            && options == 0);
    BOOL routeWasObserved =
        [_expectedMicrophoneRouteChangeTransitionCursorFingerprint
            isEqualToString:currentRouteFingerprint];
    BOOL outputIsPinned =
        _expectedMicrophoneRouteChangeOutputFingerprint.length > 0
        && [_expectedMicrophoneRouteChangeOutputFingerprint
            isEqualToString:currentOutputFingerprint];
    BOOL converged =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        && _expectedMicrophoneRouteChangeMutationSequence
            == transactionRevision
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeConfigurationGeneration
            == configurationGeneration
        && _expectedMicrophoneRouteChangeOwnershipToken == ownershipToken
        && _expectedMicrophoneRouteChangeSystemAudioGeneration
            == systemAudioGeneration
        && configurationGeneration == activeConfigurationGeneration
        && ownsSession
        && sessionActive
        && !recoveryRequired
        && !explicitResumeRequired
        && now != 0
        && now <= _expectedMicrophoneRouteChangeDeadlineNanoseconds
        && currentRouteFingerprint.length > 0
        && currentOutputFingerprint.length > 0
        && routeWasObserved
        && outputIsPinned
        && outputCount > 0
        && outputChannels == ASOutputChannelCount
        && (!inputRequired || inputChannels == ASInputChannelCount)
        && targetIsCurrent
        && targetIsPreferred
        && policyIsExact
        && [mode isEqualToString:AVAudioSessionModeDefault]
        && sharingPolicy == AVAudioSessionRouteSharingPolicyDefault;
    dispatch_semaphore_t semaphore = nil;
    if (converged) {
        _expectedMicrophoneRouteChangeState =
            ASExpectedMicrophoneRouteChangeStatePrepared;
        _expectedMicrophoneRouteChangeConvergedRouteFingerprint =
            [currentRouteFingerprint copy];
        _expectedMicrophoneRouteChangeDeadlineNanoseconds =
            now > UINT64_MAX
                    - ASExpectedMicrophoneRouteChangeLifetimeNanoseconds
            ? UINT64_MAX
            : now + ASExpectedMicrophoneRouteChangeLifetimeNanoseconds;
        semaphore = _expectedMicrophoneRouteChangeSemaphore;
        _expectedMicrophoneRouteChangeMutationSequence += 1;
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
    return converged;
}

- (BOOL)transitionExpectedMicrophoneRouteChangeForSession:
    (AVAudioSession *)session
                                    transactionIdentifier:
                                        (uint64_t)expectedTransactionIdentifier
                                            expectedState:
                                                (ASExpectedMicrophoneRouteChangeState)expectedState
                                                nextState:
                                                    (ASExpectedMicrophoneRouteChangeState)nextState
                                     requirePreparedRoute:
                                         (BOOL)requirePreparedRoute
                              validatedNotificationSequence:
                                  (uint64_t *)validatedNotificationSequence {
    if (validatedNotificationSequence != NULL) {
        *validatedNotificationSequence = 0;
    }
    if (session == nil) {
        return NO;
    }

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    uint64_t transactionIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifier;
    uint64_t transactionRevision =
        _expectedMicrophoneRouteChangeMutationSequence;
    uint64_t routeNotificationSequence =
        _routeChangeNotificationSequence;
    uint64_t configurationGeneration =
        _expectedMicrophoneRouteChangeConfigurationGeneration;
    uint64_t ownershipToken =
        _expectedMicrophoneRouteChangeOwnershipToken;
    uint64_t boundSystemAudioGeneration =
        _expectedMicrophoneRouteChangeSystemAudioGeneration;
    uint64_t transactionDeadline =
        _expectedMicrophoneRouteChangeDeadlineNanoseconds;
    NSString *targetInputIdentifier =
        _expectedMicrophoneRouteChangeTargetInputIdentifier;
    NSString *transitionCursorFingerprint =
        _expectedMicrophoneRouteChangeTransitionCursorFingerprint;
    NSString *preparedRouteFingerprint =
        _expectedMicrophoneRouteChangeConvergedRouteFingerprint;
    NSString *expectedOutputFingerprint =
        _expectedMicrophoneRouteChangeOutputFingerprint;
    ASRemoteIOStartSettlement startSettlement =
        _expectedMicrophoneRouteChangeStartSettlement;
    BOOL inputRequired = _expectedMicrophoneRouteChangeInputRequired;
    BOOL requirePreferredInput =
        _expectedMicrophoneRouteChangeRequiresPreferredInput;
    BOOL maySample =
        _expectedMicrophoneRouteChangeState == expectedState
        && transactionIdentifier != 0
        && (expectedTransactionIdentifier == 0
            || transactionIdentifier == expectedTransactionIdentifier)
        && transactionRevision != 0
        && configurationGeneration != 0
        && ownershipToken != 0
        && boundSystemAudioGeneration != 0
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (!maySample) {
        return NO;
    }

    AVAudioSessionRouteDescription *route = session.currentRoute;
    AVAudioSessionPortDescription *currentInput = route.inputs.firstObject;
    AVAudioSessionPortDescription *preferredInput = session.preferredInput;
    NSString *currentInputType = [currentInput.portType copy];
    NSString *currentInputIdentifier = [currentInput.UID copy];
    NSString *preferredInputType = [preferredInput.portType copy];
    NSString *preferredInputIdentifier = [preferredInput.UID copy];
    NSString *currentRouteFingerprint =
        ASAudioSessionRouteFingerprint(route);
    NSString *currentOutputFingerprint =
        ASAudioSessionPortsFingerprint(route.outputs);
    NSString *category = [session.category copy];
    NSString *mode = [session.mode copy];
    AVAudioSessionCategoryOptions options = session.categoryOptions;
    AVAudioSessionRouteSharingPolicy sharingPolicy =
        session.routeSharingPolicy;
    NSUInteger inputCount = route.inputs.count;
    NSUInteger outputCount = route.outputs.count;
    NSInteger inputChannels = session.inputNumberOfChannels;
    NSInteger outputChannels = session.outputNumberOfChannels;
    uint64_t now = ASMonotonicNanoseconds();
    uint64_t activeConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    uint64_t currentOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    uint64_t systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    BOOL sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_acquire
    );
    BOOL recoveryRequired = atomic_load_explicit(
        &_lifecycle.recoveryRequired,
        memory_order_acquire
    );
    BOOL explicitResumeRequired = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_acquire
    );
    BOOL ownsSession = [self sessionOwnershipMatchesToken:ownershipToken];
    BOOL targetIsCurrent = !inputRequired
        || (inputCount == 1
            && [currentInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [currentInputIdentifier
                isEqualToString:targetInputIdentifier]);
    BOOL targetIsPreferred = !requirePreferredInput
        || ([preferredInputType
                isEqualToString:AVAudioSessionPortBuiltInMic]
            && [preferredInputIdentifier
                isEqualToString:targetInputIdentifier]);
    BOOL policyIsExact = inputRequired
        ? ([category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
            && options == ASIPhoneMicrophoneCategoryOptions())
        : ([category isEqualToString:AVAudioSessionCategoryPlayback]
            && options == 0);
    BOOL routeMatchesCursor = currentRouteFingerprint.length > 0
        && [transitionCursorFingerprint
            isEqualToString:currentRouteFingerprint];
    BOOL preparedRouteMatches = !requirePreparedRoute
        || [preparedRouteFingerprint
            isEqualToString:currentRouteFingerprint];
    BOOL outputFingerprintIsExact =
        expectedOutputFingerprint.length > 0
        && [expectedOutputFingerprint
            isEqualToString:currentOutputFingerprint];
    BOOL startSettlementIsExact =
        expectedState != ASExpectedMicrophoneRouteChangeStateStarting
        || ASRemoteIOStartSettlementIsCurrent(
            startSettlement,
            transactionIdentifier,
            now
        );
    BOOL sampledEvidenceIsExact =
        configurationGeneration == activeConfigurationGeneration
        && ownershipToken == currentOwnershipToken
        && boundSystemAudioGeneration == systemAudioGeneration
        && ownsSession
        && sessionActive
        && !recoveryRequired
        && !explicitResumeRequired
        && now != 0
        && now <= transactionDeadline
        && routeMatchesCursor
        && preparedRouteMatches
        && outputFingerprintIsExact
        && startSettlementIsExact
        && outputCount > 0
        && outputChannels == ASOutputChannelCount
        && (!inputRequired || inputChannels == ASInputChannelCount)
        && targetIsCurrent
        && targetIsPreferred
        && policyIsExact
        && [mode isEqualToString:AVAudioSessionModeDefault]
        && sharingPolicy == AVAudioSessionRouteSharingPolicyDefault;

    dispatch_semaphore_t semaphore = nil;
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL targetIdentifierIsStillExact =
        (_expectedMicrophoneRouteChangeTargetInputIdentifier == nil
            && targetInputIdentifier == nil)
        || [_expectedMicrophoneRouteChangeTargetInputIdentifier
            isEqualToString:targetInputIdentifier];
    BOOL revisionIsStillExact =
        _expectedMicrophoneRouteChangeTransactionIdentifier
            == transactionIdentifier
        && _expectedMicrophoneRouteChangeMutationSequence
            == transactionRevision
        && _routeChangeNotificationSequence
            == routeNotificationSequence
        && _expectedMicrophoneRouteChangeState == expectedState
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeConfigurationGeneration
            == configurationGeneration
        && _expectedMicrophoneRouteChangeOwnershipToken == ownershipToken
        && _expectedMicrophoneRouteChangeSystemAudioGeneration
            == boundSystemAudioGeneration
        && _expectedMicrophoneRouteChangeDeadlineNanoseconds
            == transactionDeadline
        && _expectedMicrophoneRouteChangeInputRequired == inputRequired
        && _expectedMicrophoneRouteChangeRequiresPreferredInput
            == requirePreferredInput
        && targetIdentifierIsStillExact
        && [_expectedMicrophoneRouteChangeTransitionCursorFingerprint
            isEqualToString:transitionCursorFingerprint]
        && [_expectedMicrophoneRouteChangeOutputFingerprint
            isEqualToString:expectedOutputFingerprint]
        && _expectedMicrophoneRouteChangeStartSettlement
                .state
            == startSettlement.state
        && _expectedMicrophoneRouteChangeStartSettlement
                .transactionIdentifier
            == startSettlement.transactionIdentifier
        && _expectedMicrophoneRouteChangeStartSettlement
                .notificationSequenceBaseline
            == startSettlement.notificationSequenceBaseline
        && _expectedMicrophoneRouteChangeStartSettlement
                .deadlineNanoseconds
            == startSettlement.deadlineNanoseconds
        && ((_expectedMicrophoneRouteChangeConvergedRouteFingerprint == nil
                && preparedRouteFingerprint == nil)
            || [_expectedMicrophoneRouteChangeConvergedRouteFingerprint
                isEqualToString:preparedRouteFingerprint]);
    BOOL transitionIsExact =
        sampledEvidenceIsExact && revisionIsStillExact;
    BOOL committedAudioUnitStartState = NO;
    if (transitionIsExact
        && expectedState == ASExpectedMicrophoneRouteChangeStateStarting
        && nextState == ASExpectedMicrophoneRouteChangeStateConsumed) {
        // An exact reason-8 may consume the start claim before commit while the transaction is
        // still Starting. Retire that spent claim at the same locked transition that publishes
        // Consumed; an unused Armed claim remains available for one delayed post-commit ingress.
        transitionIsExact = ASCommitExpectedMicrophoneRouteChangeStartState(
            &_expectedMicrophoneRouteChangeState,
            &_expectedMicrophoneRouteChangeStartSettlement,
            transactionIdentifier,
            now
        );
        committedAudioUnitStartState = transitionIsExact;
    }
    if (transitionIsExact) {
        if (!committedAudioUnitStartState) {
            _expectedMicrophoneRouteChangeState = nextState;
        }
        _expectedMicrophoneRouteChangeDeadlineNanoseconds =
            now > UINT64_MAX
                    - ASExpectedMicrophoneRouteChangeLifetimeNanoseconds
            ? UINT64_MAX
            : now + ASExpectedMicrophoneRouteChangeLifetimeNanoseconds;
        if (nextState == ASExpectedMicrophoneRouteChangeStateConsumed) {
            _expectedMicrophoneRouteChangeConvergedRouteFingerprint =
                [currentRouteFingerprint copy];
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
        }
        _expectedMicrophoneRouteChangeMutationSequence += 1;
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
        if (validatedNotificationSequence != NULL) {
            *validatedNotificationSequence =
                routeNotificationSequence;
        }
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
    return transitionIsExact;
}

- (BOOL)waitForExpectedMicrophoneRouteChangeNotificationsToDrainInState:
    (ASExpectedMicrophoneRouteChangeState)state {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t waitDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;

    for (;;) {
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL stateMatches =
            _expectedMicrophoneRouteChangeState == state;
        BOOL drained =
            _expectedMicrophoneRouteChangeNotificationInFlightCount == 0;
        dispatch_semaphore_t semaphore = stateMatches
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!stateMatches) {
            return NO;
        }
        if (drained) {
            return YES;
        }

        uint64_t now = ASMonotonicNanoseconds();
        if (semaphore == nil || now == 0 || now >= waitDeadline) {
            return NO;
        }
        uint64_t remaining = waitDeadline - now;
        uint64_t slice = MIN(remaining, (uint64_t)10000000);
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)beginExpectedMicrophoneRouteChangeAudioUnitStartForSession:
    (AVAudioSession *)session {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t retryDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;
    for (;;) {
        if (![self
            waitForExpectedMicrophoneRouteChangeNotificationsToDrainInState:
                ASExpectedMicrophoneRouteChangeStatePrepared]) {
            return NO;
        }
        if ([self
            transitionExpectedMicrophoneRouteChangeForSession:session
            transactionIdentifier:0
            expectedState:ASExpectedMicrophoneRouteChangeStatePrepared
            nextState:ASExpectedMicrophoneRouteChangeStateStarting
            requirePreparedRoute:YES
            validatedNotificationSequence:NULL]) {
            return YES;
        }

        uint64_t now = ASMonotonicNanoseconds();
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL transactionCanRetry =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStatePrepared
            && now != 0
            && now < retryDeadline;
        dispatch_semaphore_t semaphore = transactionCanRetry
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!transactionCanRetry || semaphore == nil) {
            return NO;
        }
        uint64_t slice = MIN(
            retryDeadline - now,
            (uint64_t)10000000
        );
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)markExpectedMicrophoneRouteChangeAudioUnitStartCompleted {
    uint64_t now = ASMonotonicNanoseconds();
    if (now == 0) {
        return NO;
    }

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL reasonEightWasConsumedBeforeStamp =
        _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateConsumedWhileStarting
        && _expectedMicrophoneRouteChangeStartSettlement
                .transactionIdentifier
            == _expectedMicrophoneRouteChangeTransactionIdentifier
        && _expectedMicrophoneRouteChangeStartSettlement.deadlineNanoseconds
            == 0;
    BOOL settlementCanBeStamped =
        _expectedMicrophoneRouteChangeStartSettlement.state
            == ASRemoteIOStartSettlementStateRetired
        || reasonEightWasConsumedBeforeStamp;
    BOOL marked =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateStarting
        && _expectedMicrophoneRouteChangeTransactionIdentifier != 0
        && settlementCanBeStamped;
    dispatch_semaphore_t semaphore = nil;
    if (marked) {
        // Stamp an explicit transaction/sequence/deadline claim at the return boundary of this
        // exact AudioOutputUnitStart. Commit may publish immediately from a fresh exact route. An
        // already-consumed synchronous reason-8 stays spent; otherwise one delayed coalesced
        // reason-8 observation can still prove native-start provenance.
        _expectedMicrophoneRouteChangeStartSettlement =
            ASMakeRemoteIOStartSettlement(
                _expectedMicrophoneRouteChangeTransactionIdentifier,
                _routeChangeNotificationSequence,
                now
            );
        if (reasonEightWasConsumedBeforeStamp) {
            _expectedMicrophoneRouteChangeStartSettlement.state =
                ASRemoteIOStartSettlementStateConsumedWhileStarting;
        }
        _expectedMicrophoneRouteChangeMutationSequence += 1;
        if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
            _expectedMicrophoneRouteChangeMutationSequence = 1;
        }
        semaphore = _expectedMicrophoneRouteChangeSemaphore;
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
    return marked;
}

- (BOOL)commitExpectedMicrophoneRouteChangeAfterAudioUnitStartForSession:
    (AVAudioSession *)session {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t waitDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;

    for (;;) {
        if ([self
            transitionExpectedMicrophoneRouteChangeForSession:session
            transactionIdentifier:0
            expectedState:ASExpectedMicrophoneRouteChangeStateStarting
            nextState:ASExpectedMicrophoneRouteChangeStateConsumed
            requirePreparedRoute:NO
            validatedNotificationSequence:NULL]) {
            return YES;
        }

        uint64_t now = ASMonotonicNanoseconds();
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL transactionIsStarting =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStateStarting;
        dispatch_semaphore_t semaphore = transactionIsStarting
            ? _expectedMicrophoneRouteChangeSemaphore
            : nil;
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (!transactionIsStarting
            || semaphore == nil
            || now == 0
            || now >= waitDeadline) {
            return NO;
        }

        uint64_t remaining = waitDeadline - now;
        uint64_t slice = MIN(remaining, (uint64_t)10000000);
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (BOOL)publishCommittedExpectedMicrophoneRouteChangePlayout {
    uint64_t startedAt = ASMonotonicNanoseconds();
    if (startedAt == 0) {
        return NO;
    }
    uint64_t waitDeadline =
        startedAt > UINT64_MAX
                - ASMicrophoneRouteConvergenceTimeoutNanoseconds
        ? UINT64_MAX
        : startedAt + ASMicrophoneRouteConvergenceTimeoutNanoseconds;

    for (;;) {
        dispatch_semaphore_t semaphore = nil;
        uint64_t routeClosureTransactionIdentifier = 0;
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL stateIsCommitted =
            _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStateConsumed;
        BOOL notificationsDrained =
            _expectedMicrophoneRouteChangeNotificationInFlightCount == 0;
        BOOL publicationIsSafe =
            stateIsCommitted
            && notificationsDrained
            && !atomic_load_explicit(
                &_lifecycle.recoveryRequired,
                memory_order_acquire
            )
            && !atomic_load_explicit(
                &_lifecycle.explicitResumeRequired,
                memory_order_acquire
            )
            && ASRealtimeGateIsClosedAndDrained(
                &_realtimePlayoutDeviceGate
            );
        if (publicationIsSafe) {
            _playing = YES;
            atomic_store_explicit(
                &_lifecycle.playing,
                true,
                memory_order_release
            );
            BOOL routeEvidenceOwnsGateClosure =
                ASRouteEvidenceOwnsDeviceGateClosure(
                    _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence,
                    _expectedMicrophoneRouteChangeNotificationInFlightCount
                );
            if (routeEvidenceOwnsGateClosure) {
                routeClosureTransactionIdentifier =
                    _expectedMicrophoneRouteChangeTransactionIdentifier;
            } else {
                ASResetClosedRealtimeGate(&_realtimePlayoutDeviceGate);
            }
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
            _expectedMicrophoneRouteChangeSemaphore = nil;
            _expectedMicrophoneRouteChangeMutationSequence += 1;
            if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
                _expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        } else if (stateIsCommitted && !notificationsDrained) {
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
        }
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (publicationIsSafe) {
            if (semaphore != nil) {
                dispatch_semaphore_signal(semaphore);
            }
            if (routeClosureTransactionIdentifier != 0) {
                [self
                    scheduleExpectedMicrophoneRouteGateReopenForTransactionIdentifier:
                        routeClosureTransactionIdentifier];
            }
            return YES;
        }
        if (!stateIsCommitted || notificationsDrained || semaphore == nil) {
            return NO;
        }

        uint64_t now = ASMonotonicNanoseconds();
        if (now == 0 || now >= waitDeadline) {
            return NO;
        }
        uint64_t remaining = waitDeadline - now;
        uint64_t slice = MIN(remaining, (uint64_t)10000000);
        (void)dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice)
        );
    }
}

- (ASExpectedMicrophoneRouteChangeState)
    expectedMicrophoneRouteChangeState {
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    ASExpectedMicrophoneRouteChangeState state =
        _expectedMicrophoneRouteChangeState;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    return state;
}

- (void)enqueueExpectedMicrophoneRouteChangeNotification:
    (NSNotification *)notification
                                                reason:
                                                    (AVAudioSessionRouteChangeReason)reason
                                      resolverToken:
                                          (ASRouteConfigurationChangeResolverToken)resolverToken {
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    _routeChangeNotificationSequence += 1;
    if (_routeChangeNotificationSequence == 0) {
        _routeChangeNotificationSequence = 1;
    }
    // Ingress itself invalidates the prior capture proof. A later exact fresh-route reopen may
    // publish a new generation, but an async sender-statistics read can never bridge the event.
    atomic_store_explicit(
        &_captureRouteProofGeneration,
        0,
        memory_order_release
    );
    uint64_t notificationSequence = _routeChangeNotificationSequence;
    if (reason != AVAudioSessionRouteChangeReasonCategoryChange) {
        _nonCategoryRouteChangeNotificationSequence += 1;
        if (_nonCategoryRouteChangeNotificationSequence == 0) {
            _nonCategoryRouteChangeNotificationSequence = 1;
        }
    }
    ASExpectedMicrophoneRouteChangeState entryState =
        _expectedMicrophoneRouteChangeState;
    uint64_t transactionIdentifier =
        _expectedMicrophoneRouteChangeTransactionIdentifier;
    uint64_t entryConfigurationGeneration =
        _expectedMicrophoneRouteChangeConfigurationGeneration;
    uint64_t entrySystemAudioGeneration =
        _expectedMicrophoneRouteChangeSystemAudioGeneration;
    uint64_t observedAt = ASMonotonicNanoseconds();
    AVAudioSessionRouteDescription *previousRoute =
        notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    AVAudioSession *session = [self currentAudioSession];
    AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
    AVAudioSessionPortDescription *currentInput =
        currentRoute.inputs.firstObject;
    AVAudioSessionPortDescription *preferredInput = session.preferredInput;
    ASExpectedRouteObservationSnapshot *snapshot =
        [[ASExpectedRouteObservationSnapshot alloc] init];
    snapshot.currentRouteFingerprint =
        ASAudioSessionRouteFingerprint(currentRoute);
    snapshot.currentOutputFingerprint =
        ASAudioSessionPortsFingerprint(currentRoute.outputs);
    snapshot.currentInputType = [currentInput.portType copy];
    snapshot.currentInputIdentifier = [currentInput.UID copy];
    snapshot.preferredInputType = [preferredInput.portType copy];
    snapshot.preferredInputIdentifier = [preferredInput.UID copy];
    snapshot.category = [session.category copy];
    snapshot.mode = [session.mode copy];
    snapshot.categoryOptions = session.categoryOptions;
    snapshot.sharingPolicy = session.routeSharingPolicy;
#if DEBUG
    if (_debugExpectedCategoryObservationNotification == notification) {
        snapshot.category =
            [_debugExpectedCategoryObservationCategory copy];
        snapshot.mode = [_debugExpectedCategoryObservationMode copy];
        snapshot.categoryOptions =
            _debugExpectedCategoryObservationOptions;
        snapshot.sharingPolicy =
            _debugExpectedCategoryObservationSharingPolicy;
        _debugExpectedCategoryObservationNotification = nil;
        _debugExpectedCategoryObservationCategory = nil;
        _debugExpectedCategoryObservationMode = nil;
        _debugExpectedCategoryObservationOptions = 0;
        _debugExpectedCategoryObservationSharingPolicy =
            AVAudioSessionRouteSharingPolicyDefault;
    }
#endif
    snapshot.inputCount = currentRoute.inputs.count;
    snapshot.outputCount = currentRoute.outputs.count;
    snapshot.inputChannels = session.inputNumberOfChannels;
    snapshot.outputChannels = session.outputNumberOfChannels;
    snapshot.activeConfigurationGeneration = atomic_load_explicit(
        &_activeAudioConfigurationGeneration,
        memory_order_acquire
    );
    snapshot.currentOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    snapshot.systemAudioGeneration = atomic_load_explicit(
        &_systemAudioGeneration,
        memory_order_acquire
    );
    snapshot.sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_acquire
    );
    snapshot.recoveryRequired = atomic_load_explicit(
        &_lifecycle.recoveryRequired,
        memory_order_acquire
    );
    snapshot.explicitResumeRequired = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_acquire
    );
    snapshot.expectedInputRequired =
        _expectedMicrophoneRouteChangeInputRequired;
    snapshot.expectedObserverSequenceBaseline =
        _expectedMicrophoneRouteChangeObserverSequenceBaseline;
    snapshot.expectedDeadlineNanoseconds =
        _expectedMicrophoneRouteChangeDeadlineNanoseconds;
    snapshot.observedAt = observedAt;
    snapshot.previousRouteFingerprint = previousRoute == nil
        ? nil
        : ASAudioSessionRouteFingerprint(previousRoute);
    BOOL trackedTransaction = transactionIdentifier != 0
        && entryState != ASExpectedMicrophoneRouteChangeStateNone
        && entryState != ASExpectedMicrophoneRouteChangeStateRejected;
    if (trackedTransaction) {
        _expectedMicrophoneRouteChangeNotificationInFlightCount += 1;
    }
    BOOL mustCloseRealtimeRouteGates =
        ASMustCloseRealtimeRouteGatesForObservation(
            reason,
            atomic_load_explicit(
                &_lifecycle.playing,
                memory_order_acquire
            ),
            trackedTransaction
        );
    if (mustCloseRealtimeRouteGates) {
        [self closeRealtimeRouteGatesWithoutDraining];
        if (trackedTransaction) {
            _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence =
                YES;
        }
    }

    // Capture the complete immutable route/session snapshot and submit it
    // while the ingress lock is held. The serial evidence queue therefore
    // sees the same total order as the monotonic notification sequence and
    // never misreads two queued A->B and B->C events as A->C and B->C.
    dispatch_async(_expectedMicrophoneRouteChangeEvidenceQueue, ^{
        ASExpectedRouteObservationHandling handling = [self
            processExpectedMicrophoneRouteChangeObservationWithReason:reason
            notificationSequence:notificationSequence
            snapshot:snapshot
            transactionIdentifier:transactionIdentifier
            entryState:entryState
            entryConfigurationGeneration:entryConfigurationGeneration
            entrySystemAudioGeneration:entrySystemAudioGeneration
            trackedTransaction:trackedTransaction];
        BOOL handled = handling != ASExpectedRouteObservationHandlingGeneric;
        if (reason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange
            && handling == ASExpectedRouteObservationHandlingConsumed) {
            ASResolveRouteConfigurationChangeDisposition(
                notification,
                resolverToken,
                ASIOSRouteConfigurationChangeDispositionConsumed
            );
        } else if (reason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange
            && handling
                == ASExpectedRouteObservationHandlingLiveRejectionOwnedByWaiter) {
            ASResolveRouteConfigurationChangeDisposition(
                notification,
                resolverToken,
                ASIOSRouteConfigurationChangeDispositionLiveRejectionOwnedByWaiter
            );
        }
        BOOL supersededByNewerTransaction = NO;
        if (!handled) {
            os_unfair_lock_lock(
                &self->_expectedMicrophoneRouteChangeLock
            );
            supersededByNewerTransaction =
                ASShouldSuppressSupersededRouteConfigurationObservation(
                    reason,
                    notificationSequence,
                    transactionIdentifier,
                    self->_expectedMicrophoneRouteChangeState,
                    self->_expectedMicrophoneRouteChangeTransactionIdentifier,
                    self->_expectedMicrophoneRouteChangeObserverSequenceBaseline
                );
            os_unfair_lock_unlock(
                &self->_expectedMicrophoneRouteChangeLock
            );
        }
        if (!handled && supersededByNewerTransaction) {
            ASResolveRouteConfigurationChangeDisposition(
                notification,
                resolverToken,
                ASIOSRouteConfigurationChangeDispositionStaleSuppressed
            );
        } else if (!handled) {
            [self scheduleRouteChangedSystemEventForReason:reason
                                      notificationSequence:notificationSequence
                              capturedTransactionIdentifier:
                                  transactionIdentifier
                              capturedSystemAudioGeneration:
                                  snapshot.systemAudioGeneration
                                              notification:notification
                                          resolverToken:resolverToken];
        }
    });
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
}

- (ASExpectedRouteObservationHandling)
    processExpectedMicrophoneRouteChangeObservationWithReason:
    (AVAudioSessionRouteChangeReason)reason
                                      notificationSequence:
                                          (uint64_t)notificationSequence
                                                  snapshot:
                                                      (ASExpectedRouteObservationSnapshot *)snapshot
                                     transactionIdentifier:
                                         (uint64_t)transactionIdentifier
                                                 entryState:
                                                     (ASExpectedMicrophoneRouteChangeState)entryState
                            entryConfigurationGeneration:
                                (uint64_t)entryConfigurationGeneration
                                    entrySystemAudioGeneration:
                                        (uint64_t)entrySystemAudioGeneration
                                   trackedTransaction:
                                       (BOOL)trackedTransaction {
    NSString *currentFingerprint = snapshot.currentRouteFingerprint;
    NSString *currentOutputFingerprint = snapshot.currentOutputFingerprint;
    NSString *currentInputType = snapshot.currentInputType;
    NSString *currentInputIdentifier = snapshot.currentInputIdentifier;
    NSString *preferredInputType = snapshot.preferredInputType;
    NSString *preferredInputIdentifier = snapshot.preferredInputIdentifier;
    NSString *category = snapshot.category;
    NSString *mode = snapshot.mode;
    AVAudioSessionCategoryOptions options = snapshot.categoryOptions;
    AVAudioSessionRouteSharingPolicy sharingPolicy = snapshot.sharingPolicy;
    NSUInteger inputCount = snapshot.inputCount;
    NSUInteger outputCount = snapshot.outputCount;
    NSInteger inputChannels = snapshot.inputChannels;
    NSInteger outputChannels = snapshot.outputChannels;
    uint64_t activeConfigurationGeneration =
        snapshot.activeConfigurationGeneration;
    uint64_t currentOwnershipToken = snapshot.currentOwnershipToken;
    uint64_t systemAudioGeneration = snapshot.systemAudioGeneration;
    BOOL sessionActive = snapshot.sessionActive;
    BOOL recoveryRequired = snapshot.recoveryRequired;
    BOOL explicitResumeRequired = snapshot.explicitResumeRequired;
    BOOL expectedInputRequired = snapshot.expectedInputRequired;
    uint64_t expectedObserverSequenceBaseline =
        snapshot.expectedObserverSequenceBaseline;
    uint64_t expectedDeadlineNanoseconds =
        snapshot.expectedDeadlineNanoseconds;
    uint64_t observedAt = snapshot.observedAt;
    NSString *previousFingerprint = snapshot.previousRouteFingerprint;

    BOOL expectedCategoryObservation =
        ASExpectedCategoryObservationMatchesCapturedPolicy(
            reason,
            trackedTransaction,
            entryState,
            transactionIdentifier,
            entryConfigurationGeneration,
            activeConfigurationGeneration,
            entrySystemAudioGeneration,
            systemAudioGeneration,
            notificationSequence,
            expectedObserverSequenceBaseline,
            observedAt,
            expectedDeadlineNanoseconds,
            expectedInputRequired,
            category,
            mode,
            options,
            sharingPolicy
        );

    ASIOSExpectedRouteChangeDisposition disposition =
        ASIOSExpectedRouteChangeDispositionUnrelated;
    BOOL observationBelongsToTransaction = NO;
    BOOL liveRouteConfigurationRejectionOwnedByWaiter = NO;
    dispatch_semaphore_t semaphore = nil;
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    observationBelongsToTransaction = trackedTransaction
        && transactionIdentifier != 0
        && _expectedMicrophoneRouteChangeTransactionIdentifier
            == transactionIdentifier
        && _expectedMicrophoneRouteChangeState == entryState
        && _expectedMicrophoneRouteChangeConfigurationGeneration
            == entryConfigurationGeneration
        && _expectedMicrophoneRouteChangeSystemAudioGeneration
            == entrySystemAudioGeneration;
    if (observationBelongsToTransaction) {
        ASExpectedMicrophoneRouteChangeState state =
            _expectedMicrophoneRouteChangeState;
        NSString *targetIdentifier =
            _expectedMicrophoneRouteChangeTargetInputIdentifier;
        BOOL inputRequired = _expectedMicrophoneRouteChangeInputRequired;
        BOOL targetIsCurrent = !inputRequired
            || (inputCount == 1
                && [currentInputType
                    isEqualToString:AVAudioSessionPortBuiltInMic]
                && [currentInputIdentifier
                    isEqualToString:targetIdentifier]);
        BOOL targetIsPreferred =
            !_expectedMicrophoneRouteChangeRequiresPreferredInput
            || ([preferredInputType
                    isEqualToString:AVAudioSessionPortBuiltInMic]
                && [preferredInputIdentifier
                    isEqualToString:targetIdentifier]);
        BOOL policyIsExact = inputRequired
            ? ([category
                    isEqualToString:AVAudioSessionCategoryPlayAndRecord]
                && options == ASIPhoneMicrophoneCategoryOptions())
            : ([category isEqualToString:AVAudioSessionCategoryPlayback]
                && options == 0);
        BOOL outputIsExact =
            _expectedMicrophoneRouteChangeOutputFingerprint.length > 0
            && [_expectedMicrophoneRouteChangeOutputFingerprint
                isEqualToString:currentOutputFingerprint];
        BOOL currentRouteMatchesConvergedRoute =
            [_expectedMicrophoneRouteChangeConvergedRouteFingerprint
                isEqualToString:currentFingerprint];
        BOOL remoteIOStartSettlementProvenanceMatches =
            reason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange
            && ASRemoteIOStartSettlementAuthorizesObservation(
                _expectedMicrophoneRouteChangeStartSettlement,
                transactionIdentifier,
                notificationSequence,
                observedAt
            );
        ASExpectedRouteChangeEvidence evidence = {
            .state = state,
            .reason = reason,
            .sequenceAdvanced = notificationSequence
                > _expectedMicrophoneRouteChangeObserverSequenceBaseline,
            .withinDeadline = observedAt != 0
                && observedAt
                    <= _expectedMicrophoneRouteChangeDeadlineNanoseconds,
            .configurationGenerationMatches =
                activeConfigurationGeneration
                    == _expectedMicrophoneRouteChangeConfigurationGeneration,
            .systemAudioGenerationMatches = systemAudioGeneration
                == _expectedMicrophoneRouteChangeSystemAudioGeneration,
            .fingerprintsArePresent = currentFingerprint.length > 0
                && previousFingerprint.length > 0,
            .previousFingerprintWasObserved =
                [_expectedMicrophoneRouteChangeTransitionCursorFingerprint
                    isEqualToString:previousFingerprint],
            .policyIsExact = policyIsExact
                && [mode isEqualToString:AVAudioSessionModeDefault]
                && sharingPolicy
                    == AVAudioSessionRouteSharingPolicyDefault,
            .ownershipIsBound =
                _expectedMicrophoneRouteChangeOwnershipToken != 0,
            .ownershipMatches =
                _expectedMicrophoneRouteChangeOwnershipToken
                    == currentOwnershipToken,
            .sessionActive = sessionActive,
            .recoveryRequired = recoveryRequired,
            .explicitResumeRequired = explicitResumeRequired,
            .currentRouteMatchesConvergedRoute =
                currentRouteMatchesConvergedRoute,
            .outputIsExact = outputIsExact,
            .channelsAreExact = outputChannels == ASOutputChannelCount
                && (!inputRequired
                    || inputChannels == ASInputChannelCount),
            .targetInputIsExact = targetIsCurrent,
            .preferredInputIsExact = targetIsPreferred,
            .remoteIOStartSettlementProvenanceMatches =
                remoteIOStartSettlementProvenanceMatches,
        };
        disposition = ASClassifyExpectedRouteChangeEvidence(evidence);
        BOOL transactionIsLive =
            state == ASExpectedMicrophoneRouteChangeStatePending
            || state == ASExpectedMicrophoneRouteChangeStatePrepared
            || state == ASExpectedMicrophoneRouteChangeStateStarting;
        if (disposition == ASIOSExpectedRouteChangeDispositionConsume
            && transactionIsLive) {
            if (state == ASExpectedMicrophoneRouteChangeStateStarting
                && reason
                    == AVAudioSessionRouteChangeReasonRouteConfigurationChange
                && !ASConsumeRemoteIOStartSettlementWhileStarting(
                    &_expectedMicrophoneRouteChangeStartSettlement,
                    transactionIdentifier
                )) {
                ASFailRealtimeGateInvariant();
            }
            _expectedMicrophoneRouteChangeTransitionCursorFingerprint =
                [currentFingerprint copy];
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
            _expectedMicrophoneRouteChangeMutationSequence += 1;
            if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
                _expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        } else if (disposition
                == ASIOSExpectedRouteChangeDispositionConsume
            && state == ASExpectedMicrophoneRouteChangeStateConsumed
            && remoteIOStartSettlementProvenanceMatches) {
            // The exact start claim is one-shot. Once one delayed observation uses it, every later
            // duplicate must carry the ordinary previous-route chain or fail closed.
            ASRetireRemoteIOStartSettlement(
                &_expectedMicrophoneRouteChangeStartSettlement
            );
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
            _expectedMicrophoneRouteChangeMutationSequence += 1;
            if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
                _expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        } else if (disposition
            == ASIOSExpectedRouteChangeDispositionRejectTransaction) {
            liveRouteConfigurationRejectionOwnedByWaiter =
                transactionIsLive
                && reason
                    == AVAudioSessionRouteChangeReasonRouteConfigurationChange;
            _expectedMicrophoneRouteChangeRejectionSnapshot =
                ASImmutableRouteObservationRejectionDescription(
                    snapshot,
                    reason,
                    notificationSequence,
                    transactionIdentifier,
                    entryState,
                    _expectedMicrophoneRouteChangeConfigurationGeneration,
                    _expectedMicrophoneRouteChangeSystemAudioGeneration,
                    _expectedMicrophoneRouteChangeOwnershipToken
                );
            _expectedMicrophoneRouteChangeState =
                ASExpectedMicrophoneRouteChangeStateRejected;
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
            _expectedMicrophoneRouteChangeMutationSequence += 1;
            if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
                _expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        } else if (state
                == ASExpectedMicrophoneRouteChangeStateConsumed
            && disposition
                == ASIOSExpectedRouteChangeDispositionUnrelated
            && reason
                != AVAudioSessionRouteChangeReasonCategoryChange) {
            _expectedMicrophoneRouteChangeRejectionSnapshot =
                ASImmutableRouteObservationRejectionDescription(
                    snapshot,
                    reason,
                    notificationSequence,
                    transactionIdentifier,
                    entryState,
                    _expectedMicrophoneRouteChangeConfigurationGeneration,
                    _expectedMicrophoneRouteChangeSystemAudioGeneration,
                    _expectedMicrophoneRouteChangeOwnershipToken
                );
            _expectedMicrophoneRouteChangeState =
                ASExpectedMicrophoneRouteChangeStateRejected;
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
            _expectedMicrophoneRouteChangeMutationSequence += 1;
            if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
                _expectedMicrophoneRouteChangeMutationSequence = 1;
            }
        }
    }

    BOOL sameTransactionIdentifier = trackedTransaction
        && ASQueuedRouteObservationMatchesTransactionIdentifier(
            transactionIdentifier,
            _expectedMicrophoneRouteChangeTransactionIdentifier
        );
    if (sameTransactionIdentifier) {
        if (_expectedMicrophoneRouteChangeNotificationInFlightCount == 0) {
            ASFailRealtimeGateInvariant();
        }
        _expectedMicrophoneRouteChangeNotificationInFlightCount -= 1;
        if (semaphore == nil) {
            semaphore = _expectedMicrophoneRouteChangeSemaphore;
        }
    }
    BOOL consumed = observationBelongsToTransaction
        && disposition == ASIOSExpectedRouteChangeDispositionConsume;
    BOOL shouldScheduleRealtimeRouteGateReopen =
        sameTransactionIdentifier
        && ASShouldScheduleRouteGateClosureResolution(
            _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence,
            _expectedMicrophoneRouteChangeNotificationInFlightCount,
            _expectedMicrophoneRouteChangeState,
            atomic_load_explicit(
                &_lifecycle.playing,
                memory_order_acquire
            )
        );
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
    if (shouldScheduleRealtimeRouteGateReopen) {
        [self
            scheduleExpectedMicrophoneRouteGateReopenForTransactionIdentifier:
                transactionIdentifier];
    }

    // A live reason-8 rejection is already owned by the configuration waiter,
    // which will roll back that exact transaction. Forwarding a second stale
    // generic event could tear down a later session. Physical device loss and
    // every other reason still flow to the generic fail-closed policy.
    if (consumed) {
        return ASExpectedRouteObservationHandlingConsumed;
    }
    if (liveRouteConfigurationRejectionOwnedByWaiter) {
        return ASExpectedRouteObservationHandlingLiveRejectionOwnedByWaiter;
    }
    if (expectedCategoryObservation) {
        return ASExpectedRouteObservationHandlingExpectedCategory;
    }
    return ASExpectedRouteObservationHandlingGeneric;
}

- (void)scheduleExpectedMicrophoneRouteGateReopenForTransactionIdentifier:
    (uint64_t)transactionIdentifier {
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil || transactionIdentifier == 0) {
        return;
    }
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        BOOL initialized = self != nil && atomic_load_explicit(
            &self->_lifecycle.initialized,
            memory_order_acquire
        );
        if (!initialized) {
            return;
        }
        [self
            reopenExpectedMicrophoneRouteGatesForTransactionIdentifier:
                transactionIdentifier];
    }];
}

- (void)reopenExpectedMicrophoneRouteGatesForTransactionIdentifier:
    (uint64_t)transactionIdentifier {
    // This method runs on WebRTC's serialized device queue, alongside
    // stopRecording, authorization replacement, and teardown. It is the only
    // place where an exact post-publication route observation may reopen the
    // microphone device gate.
    __attribute__((cleanup(ASReleaseUnfairLockScope)))
    ASUnfairLockScope routeReopenConfigurationScope = {
        .lock = NULL,
    };
    os_unfair_lock_lock(&ASSessionConfigurationLock);
    routeReopenConfigurationScope.lock = &ASSessionConfigurationLock;

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    BOOL ownsRouteClosure =
        transactionIdentifier != 0
        && _expectedMicrophoneRouteChangeTransactionIdentifier
            == transactionIdentifier
        && _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateConsumed
        && atomic_load_explicit(
            &_lifecycle.playing,
            memory_order_acquire
        )
        && !atomic_load_explicit(
            &_lifecycle.recoveryRequired,
            memory_order_acquire
        )
        && !atomic_load_explicit(
            &_lifecycle.explicitResumeRequired,
            memory_order_acquire
        );
    BOOL playoutGateWasClosed = ownsRouteClosure
        && ASRealtimeGateIsClosed(&_realtimePlayoutDeviceGate);
    BOOL microphoneGateWasClosed = ownsRouteClosure
        && ASRealtimeGateIsClosed(&_realtimeMicrophoneDeviceGate);
    uint64_t resolutionStartNotificationSequence = ownsRouteClosure
        ? _routeChangeNotificationSequence
        : 0;
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (!ownsRouteClosure) {
        return;
    }

    // The final queued notification can be a category observation whose
    // immutable ingress snapshot was transient even though an earlier exact
    // reason-8 observation owned the closure. Resolve from a fresh session
    // snapshot on the serialized device queue; never let the last queued
    // snapshot choose between reopening and rollback.
    uint64_t validatedNotificationSequence = 0;
    BOOL liveRouteIsExact = [self
        transitionExpectedMicrophoneRouteChangeForSession:
            [self currentAudioSession]
        transactionIdentifier:transactionIdentifier
        expectedState:ASExpectedMicrophoneRouteChangeStateConsumed
        nextState:ASExpectedMicrophoneRouteChangeStateConsumed
        requirePreparedRoute:YES
        validatedNotificationSequence:&validatedNotificationSequence];
    if (!liveRouteIsExact) {
        os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
        BOOL stillOwnsInexactClosure =
            _expectedMicrophoneRouteChangeTransactionIdentifier
                == transactionIdentifier
            && _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence
            && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
            && _expectedMicrophoneRouteChangeState
                == ASExpectedMicrophoneRouteChangeStateConsumed
            && ASValidatedRouteNotificationSequenceIsCurrent(
                resolutionStartNotificationSequence,
                _routeChangeNotificationSequence
            );
        os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
        if (stillOwnsInexactClosure) {
            NSString *routeSnapshot = [self
                routeTransactionFailureSnapshotForPhase:
                    ASRouteTransactionDiagnosticPhaseFreshReopen
                session:[self currentAudioSession]
                expectedTransactionIdentifier:transactionIdentifier
                requiredNotificationSequence:
                    resolutionStartNotificationSequence];
            _recoveryRequired = YES;
            atomic_store_explicit(
                &_lifecycle.recoveryRequired,
                true,
                memory_order_relaxed
            );
            [self failClosedForSystemEventWithCode:
                ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                                       message:[NSString stringWithFormat:
                                           @"Fresh route evidence did not match the consumed microphone transaction; application-authorized recovery is required. %@",
                                           routeSnapshot]];
        }
        return;
    }

    // Never busy-wait while holding the route lock. A newer notification may
    // close the gates again while these admissions drain; the second token
    // check below will then leave the closure owned by that newer evidence.
    if (playoutGateWasClosed) {
        ASAssertRealtimeGateCanDrain(&_realtimePlayoutDeviceGate);
        ASDrainRealtimeGate(&_realtimePlayoutDeviceGate);
    }
    if (microphoneGateWasClosed) {
        ASAssertRealtimeGateCanDrain(&_realtimeMicrophoneDeviceGate);
        ASDrainRealtimeGate(&_realtimeMicrophoneDeviceGate);
    }

    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    uint64_t currentOwnershipToken = atomic_load_explicit(
        &ASCurrentSessionOwnershipTokenSnapshot,
        memory_order_acquire
    );
    BOOL sessionOwnershipStillExact =
#if DEBUG
        _debugRecoveryHarnessMode
            ? (_expectedMicrophoneRouteChangeOwnershipToken != 0
                && _debugOwnsSessionActivation
                && _sessionOwnershipToken
                    == _expectedMicrophoneRouteChangeOwnershipToken)
            :
#endif
        ASBoundOwnershipTokenMatchesSnapshot(
            _expectedMicrophoneRouteChangeOwnershipToken,
            currentOwnershipToken
        );
    BOOL stillOwnsRouteClosure =
        _expectedMicrophoneRouteChangeTransactionIdentifier
            == transactionIdentifier
        && _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence
        && _expectedMicrophoneRouteChangeNotificationInFlightCount == 0
        && _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateConsumed
        && _expectedMicrophoneRouteChangeConfigurationGeneration
            == atomic_load_explicit(
                &_activeAudioConfigurationGeneration,
                memory_order_acquire
            )
        && _expectedMicrophoneRouteChangeSystemAudioGeneration
            == atomic_load_explicit(
                &_systemAudioGeneration,
                memory_order_acquire
            )
        && sessionOwnershipStillExact
        && atomic_load_explicit(
            &_lifecycle.sessionActive,
            memory_order_acquire
        )
        && ASValidatedRouteNotificationSequenceIsCurrent(
            validatedNotificationSequence,
            _routeChangeNotificationSequence
        )
        && atomic_load_explicit(
            &_lifecycle.playing,
            memory_order_acquire
        )
        && !atomic_load_explicit(
            &_lifecycle.recoveryRequired,
            memory_order_acquire
        )
        && !atomic_load_explicit(
            &_lifecycle.explicitResumeRequired,
            memory_order_acquire
        )
        && (!playoutGateWasClosed
            || ASRealtimeGateIsClosedAndDrained(
                &_realtimePlayoutDeviceGate
            ))
        && (!microphoneGateWasClosed
            || ASRealtimeGateIsClosedAndDrained(
                &_realtimeMicrophoneDeviceGate
            ));
    if (stillOwnsRouteClosure) {
        if (playoutGateWasClosed) {
            ASResetClosedRealtimeGate(&_realtimePlayoutDeviceGate);
        }
        uint64_t recordingGeneration = atomic_load_explicit(
            &_realtimeMicrophoneRecordingGeneration,
            memory_order_acquire
        );
        uint64_t approvedGeneration = atomic_load_explicit(
            &_realtimeApprovedMicrophoneRecordingGeneration,
            memory_order_acquire
        );
        unsigned long authorizationGateBits = atomic_load_explicit(
            &_realtimeMicrophoneAuthorizationGate,
            memory_order_acquire
        );
        if (microphoneGateWasClosed
            && _inputBusEnabled
            && _recording
            && recordingGeneration != 0
            && recordingGeneration == approvedGeneration
            && authorizationGateBits != 0
            && ASMicrophoneAuthorizationIsValid(
                _microphoneAuthorization
            )) {
            (void)[self publishNextCaptureRouteProofGeneration];
            ASResetClosedRealtimeGate(&_realtimeMicrophoneDeviceGate);
        }
        _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence = NO;
    }
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
}

- (dispatch_semaphore_t)clearExpectedMicrophoneRouteChangeWhileHoldingLock {
    atomic_store_explicit(
        &_captureRouteProofGeneration,
        0,
        memory_order_release
    );
    BOOL mustSignal =
        _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePending
        || _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStatePrepared
        || _expectedMicrophoneRouteChangeState
            == ASExpectedMicrophoneRouteChangeStateStarting;
    dispatch_semaphore_t semaphore = mustSignal
        ? _expectedMicrophoneRouteChangeSemaphore
        : nil;
    _expectedMicrophoneRouteChangeState =
        ASExpectedMicrophoneRouteChangeStateNone;
    // Retire the immutable identifier before clearing the in-flight count.
    // Evidence already queued for the old identifier must become a no-op;
    // otherwise its completion could observe a zero count and trap after a
    // concurrent rollback/rearm.
    _expectedMicrophoneRouteChangeTransactionIdentifier = 0;
    _expectedMicrophoneRouteChangeConfigurationGeneration = 0;
    _expectedMicrophoneRouteChangeOwnershipToken = 0;
    _expectedMicrophoneRouteChangeSystemAudioGeneration = 0;
    _expectedMicrophoneRouteChangeObserverSequenceBaseline = 0;
    _expectedMicrophoneRouteChangeDeadlineNanoseconds = 0;
    ASRetireRemoteIOStartSettlement(
        &_expectedMicrophoneRouteChangeStartSettlement
    );
    _expectedMicrophoneRouteChangeRealtimeGatesClosedForEvidence = NO;
    _expectedMicrophoneRouteChangeTransitionCursorFingerprint = nil;
    _expectedMicrophoneRouteChangeConvergedRouteFingerprint = nil;
    _expectedMicrophoneRouteChangeOutputFingerprint = nil;
    _expectedMicrophoneRouteChangeTargetInputIdentifier = nil;
    _expectedMicrophoneRouteChangeInputRequired = NO;
    _expectedMicrophoneRouteChangeRequiresPreferredInput = NO;
    _expectedMicrophoneRouteChangeSemaphore = nil;
    _expectedMicrophoneRouteChangeRejectionSnapshot = nil;
    _expectedMicrophoneRouteChangeNotificationInFlightCount = 0;
    _expectedMicrophoneRouteChangeMutationSequence += 1;
    if (_expectedMicrophoneRouteChangeMutationSequence == 0) {
        _expectedMicrophoneRouteChangeMutationSequence = 1;
    }
    return semaphore;
}

- (void)clearExpectedMicrophoneRouteChange {
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    dispatch_semaphore_t semaphore =
        [self clearExpectedMicrophoneRouteChangeWhileHoldingLock];
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
}

- (void)closeRealtimeRouteGatesAndRetireExpectedMicrophoneRouteChangeForSystemEvent {
    os_unfair_lock_lock(&_expectedMicrophoneRouteChangeLock);
    // Publish the fail-closed lifecycle bit before any gate reset can inspect
    // this boundary, then close and retire while holding the same lock used by
    // every production gate opener. A notification can therefore win either
    // before or after an opener, but its closure can never be lost between
    // close and transaction retirement.
    atomic_store_explicit(
        &_lifecycle.recoveryRequired,
        true,
        memory_order_release
    );
    [self closeRealtimeRouteGatesWithoutDraining];
    dispatch_semaphore_t semaphore =
        [self clearExpectedMicrophoneRouteChangeWhileHoldingLock];
    os_unfair_lock_unlock(&_expectedMicrophoneRouteChangeLock);
    if (semaphore != nil) {
        dispatch_semaphore_signal(semaphore);
    }
}

- (void)failAndRollbackWithCode:(ASIOSStereoPlayoutFailureCode)code
                         status:(int32_t)status
                        message:(NSString *)message {
    BOOL retiringHostedCallPolicy = _hostedCallAuthorization != nil;
    [self advanceSystemAudioGeneration];
    [self revokeHostedCallAuthorization];
    if (retiringHostedCallPolicy && _wantsPlayout) {
        _recoveryRequired = YES;
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            true,
            memory_order_relaxed
        );
    }

    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    NSMutableString *detail = [message mutableCopy];
    if (teardownStatus != noErr) {
        [detail appendFormat:@" RemoteIO teardown also failed (%d).", (int)teardownStatus];
    }
    if (!deactivated) {
        [detail appendFormat:
            @" Audio-session rollback also failed: %@.",
            deactivationError.localizedDescription ?: @"unknown error"];
    }
    [self publishFailureCode:code status:status message:detail];
}

- (void)publishFailureCode:(ASIOSStereoPlayoutFailureCode)code
                     status:(int32_t)status
                    message:(NSString *)message {
    ASIOSStereoPlayoutFailureCode currentCode =
        (ASIOSStereoPlayoutFailureCode)atomic_load_explicit(
            &_lifecycle.failureCode,
            memory_order_acquire
        );
    BOOL explicitResumeIsLatched = atomic_load_explicit(
        &_lifecycle.explicitResumeRequired,
        memory_order_acquire
    );
    if (code != ASIOSStereoPlayoutFailureRouteRequiresExplicitResume
        && currentCode
            == ASIOSStereoPlayoutFailureRouteRequiresExplicitResume
        && explicitResumeIsLatched) {
        return;
    }
    atomic_store_explicit(&_lifecycle.failureCode, code, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.lastLifecycleStatus, status, memory_order_relaxed);
    self.lastLifecycleFailureMessage = message;
}

- (void)clearLifecycleFailure {
    atomic_store_explicit(
        &_lifecycle.failureCode,
        ASIOSStereoPlayoutFailureNone,
        memory_order_relaxed
    );
    atomic_store_explicit(&_lifecycle.lastLifecycleStatus, noErr, memory_order_relaxed);
    self.lastLifecycleFailureMessage = nil;
}

- (OSStatus)stopAndDisposeAudioUnit {
    [self clearExpectedMicrophoneRouteChange];
    atomic_store_explicit(
        &_activeAudioConfigurationGeneration,
        0,
        memory_order_release
    );
    [self closeAndFenceRealtimePlayoutResources];
    [self closeAndFenceRealtimeMicrophoneResources];
    [self clearCurrentMicrophoneRecordingGeneration];
    _playing = NO;
    atomic_store_explicit(
        &_lifecycle.playing,
        false,
        memory_order_release
    );
    OSStatus firstFailure = noErr;
    if (_audioUnit != NULL) {
        OSStatus stopStatus = ASStopAudioUnitIfRunning(
            _audioUnit,
            &_audioUnitRunning,
            AudioOutputUnitStop
        );
        if (stopStatus != noErr) {
            firstFailure = stopStatus;
        }
        OSStatus uninitializeStatus = AudioUnitUninitialize(_audioUnit);
        if (firstFailure == noErr && uninitializeStatus != noErr) {
            firstFailure = uninitializeStatus;
        }
        OSStatus disposeStatus = AudioComponentInstanceDispose(_audioUnit);
        if (firstFailure == noErr && disposeStatus != noErr) {
            firstFailure = disposeStatus;
        }
        _audioUnit = NULL;
    }
    free(_recordingSamples);
    _recordingSamples = NULL;
    _recordingSampleCapacity = 0;
    _recording = NO;
    _playoutInitialized = NO;
    _inputBusEnabled = NO;
    _outputBusEnabled = NO;
    _audioUnitSubType = 0;
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        _debugHealthyPlayoutForTesting = NO;
    }
#endif
    atomic_store_explicit(&_lifecycle.playoutInitialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.remoteIOCreated, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.inputBusEnabled, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.outputBusEnabled, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.audioUnitSubType, 0, memory_order_relaxed);
    return firstFailure;
}

- (BOOL)microphoneShouldBeActive {
    return ![self hostedCallModeIsAuthorized]
        && _wantsRecording
        && ASMicrophoneAuthorizationIsValid(_microphoneAuthorization);
}

- (BOOL)rebuildForCurrentPolicy {
    if (_isRebuilding) {
        return NO;
    }

    ASIOSHostedCallPlayoutAuthorization *expectedHostedAuthorization =
        _hostedCallAuthorization;
    NSUUID *expectedHostedPolicyIdentifier =
        [_hostedCallPolicyIdentifier copy];
    uint64_t expectedHostedGeneration =
        _hostedCallAuthorizationGeneration;
    BOOL hadHostedCallOwnership =
        expectedHostedAuthorization != nil
        || expectedHostedPolicyIdentifier != nil
        || expectedHostedGeneration != 0;
    BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
    if (hadHostedCallOwnership && !hostedCallMode) {
        [self advanceSystemAudioGeneration];
        [self revokeHostedCallAuthorization];
        [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
            @"A revoked or inadmissible hosted-call policy cannot cross into an ordinary native rebuild."];
        return NO;
    }

    _isRebuilding = YES;
    BOOL shouldResume = _wantsPlayout
        && (!_interrupted || hostedCallMode)
        && !_explicitResumeRequired;
    if (_inputBusEnabled) {
        [self.delegate notifyAudioInputInterrupted];
    }
    if (_audioUnit != NULL || _playing) {
        [self.delegate notifyAudioOutputInterrupted];
    }
    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    if (teardownStatus != noErr) {
        if (hostedCallMode) {
            [self advanceSystemAudioGeneration];
            [self revokeHostedCallAuthorization];
            _recoveryRequired = YES;
            atomic_store_explicit(
                &_lifecycle.recoveryRequired,
                true,
                memory_order_relaxed
            );
        }
        [self publishFailureCode:ASIOSStereoPlayoutFailureAudioUnitStop
                         status:(int32_t)teardownStatus
                        message:[NSString stringWithFormat:
                            @"RemoteIO teardown failed before explicit recovery (%d).",
                            (int)teardownStatus]];
        _isRebuilding = NO;
        return NO;
    }
    if (!deactivated) {
        if (hostedCallMode) {
            [self advanceSystemAudioGeneration];
            [self revokeHostedCallAuthorization];
            _recoveryRequired = YES;
            atomic_store_explicit(
                &_lifecycle.recoveryRequired,
                true,
                memory_order_relaxed
            );
        }
        [self publishFailureCode:ASIOSStereoPlayoutFailureSessionDeactivation
                         status:(int32_t)deactivationError.code
                        message:[NSString stringWithFormat:
                            @"Audio-session deactivation failed before explicit recovery: %@",
                            deactivationError.localizedDescription ?: @"unknown error"]];
        _isRebuilding = NO;
        return NO;
    }

    if (hostedCallMode
        && ![self
            hostedCallOwnershipMatchesAuthorization:
                expectedHostedAuthorization
            policyIdentifier:expectedHostedPolicyIdentifier
            generation:expectedHostedGeneration]) {
        [self advanceSystemAudioGeneration];
        [self revokeHostedCallAuthorization];
        _isRebuilding = NO;
        [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
            @"Hosted-call ownership changed during teardown; ordinary audio was not rebuilt."];
        return NO;
    }

    if (!shouldResume) {
        if (!_interrupted && !_recoveryRequired && !_explicitResumeRequired) {
            [self clearLifecycleFailure];
        }
        _isRebuilding = NO;
        return YES;
    }

#if DEBUG
    if (_debugRecoveryHarnessMode) {
        if (![self configureSessionAndCreateRemoteIO]) {
            if (hostedCallMode) {
                [self advanceSystemAudioGeneration];
                [self revokeHostedCallAuthorization];
                _recoveryRequired = YES;
                atomic_store_explicit(
                    &_lifecycle.recoveryRequired,
                    true,
                    memory_order_relaxed
                );
            }
            _isRebuilding = NO;
            return NO;
        }

        if (hostedCallMode
            && ![self
                hostedCallOwnershipMatchesAuthorization:
                    expectedHostedAuthorization
                policyIdentifier:expectedHostedPolicyIdentifier
                generation:expectedHostedGeneration]) {
            [self advanceSystemAudioGeneration];
            [self revokeHostedCallAuthorization];
            _isRebuilding = NO;
            [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
                @"Hosted-call ownership changed during deterministic configuration; ordinary audio was not published."];
            return NO;
        }

        BOOL microphoneEnabled = [self microphoneShouldBeActive];
        ASAudioPolicyConfiguration configuration =
            ASMakeAudioPolicyConfiguration(
                hostedCallMode,
                microphoneEnabled,
                _streamFormat
            );
        if (![self sessionMatchesCurrentPolicy:nil]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionConfiguration
                                   status:kAudio_ParamError
                                  message:@"The deterministic rebuild no longer matches the selected production policy."];
            _recoveryRequired = YES;
            atomic_store_explicit(
                &_lifecycle.recoveryRequired,
                true,
                memory_order_relaxed
            );
            _isRebuilding = NO;
            return NO;
        }

        _debugHealthyPlayoutForTesting = !hostedCallMode;
        _debugOwnsSessionActivation = YES;
        _sessionActive = YES;
        _playoutInitialized = YES;
        _playing = YES;
        _inputBusEnabled = configuration.inputBusEnabled;
        _outputBusEnabled = configuration.outputBusEnabled;
        _recording = configuration.inputBusEnabled;
        // The harness drives policy/revocation state after the real configuration-selection
        // boundary, but deliberately leaves the hardware-creation diagnostics false.
        _audioUnitSubType = 0;
        _recoveryRequired = NO;
        _explicitResumeRequired = NO;
        atomic_store_explicit(&_lifecycle.sessionActive, true, memory_order_relaxed);
        atomic_store_explicit(
            &_lifecycle.playoutInitialized,
            true,
            memory_order_relaxed
        );
        atomic_store_explicit(&_lifecycle.playing, true, memory_order_relaxed);
        atomic_store_explicit(
            &_lifecycle.remoteIOCreated,
            false,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.inputBusEnabled,
            configuration.inputBusEnabled,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.outputBusEnabled,
            configuration.outputBusEnabled,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.audioUnitSubType,
            0,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            false,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &_lifecycle.explicitResumeRequired,
            false,
            memory_order_relaxed
        );

        if (hostedCallMode
            && ![self
                hostedCallOwnershipMatchesAuthorization:
                    expectedHostedAuthorization
                policyIdentifier:expectedHostedPolicyIdentifier
                generation:expectedHostedGeneration]) {
            [self advanceSystemAudioGeneration];
            [self revokeHostedCallAuthorization];
            _isRebuilding = NO;
            [self remainQuiescentAfterHostedCallOwnershipLossWithMessage:
                @"Hosted-call ownership changed before deterministic topology publication."];
            return NO;
        }

        [self.delegate notifyAudioOutputParametersChange];
        if (configuration.inputBusEnabled) {
            [self.delegate notifyAudioInputParametersChange];
        }

        [self clearLifecycleFailure];
        _isRebuilding = NO;
        return YES;
    }
#endif

    BOOL rebuilt = NO;
    if ([self configureSessionAndCreateRemoteIO]) {
        BOOL exactHostedPolicy = !hostedCallMode
            || [self
                hostedCallOwnershipMatchesAuthorization:
                    expectedHostedAuthorization
                policyIdentifier:expectedHostedPolicyIdentifier
                generation:expectedHostedGeneration];
        if (exactHostedPolicy) {
            [self.delegate notifyAudioOutputParametersChange];
            if (_inputBusEnabled) {
                [self.delegate notifyAudioInputParametersChange];
            }
            rebuilt = [self startPlayoutForCurrentPolicy];
        }
    }
    if (!rebuilt && hostedCallMode) {
        [self advanceSystemAudioGeneration];
        [self revokeHostedCallAuthorization];
        _recoveryRequired = YES;
        atomic_store_explicit(
            &_lifecycle.recoveryRequired,
            true,
            memory_order_relaxed
        );
        (void)[self stopAndDisposeAudioUnit];
        (void)[self deactivateOwnedSessionWithError:nil];
    }
    _isRebuilding = NO;
    return rebuilt;
}

- (BOOL)rebuildAfterExplicitRecovery {
    ASCrossExplicitRecoveryBoundary(&_realtime);
    return [self rebuildForCurrentPolicy];
}

- (void)scheduleSystemEvent:(ASSystemAudioEvent)event
                routeReason:(AVAudioSessionRouteChangeReason)routeReason {
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil || !self->_initialized) {
            return;
        }
        [self handleSystemEvent:event routeReason:routeReason];
    }];
}

- (void)scheduleRouteChangedSystemEventForReason:
    (AVAudioSessionRouteChangeReason)routeReason
                                  notificationSequence:
                                      (uint64_t)notificationSequence
                          capturedTransactionIdentifier:
                              (uint64_t)capturedTransactionIdentifier
                          capturedSystemAudioGeneration:
                              (uint64_t)capturedSystemAudioGeneration
                                      notification:
                                          (NSNotification *)notification
                                      resolverToken:
                                          (ASRouteConfigurationChangeResolverToken)resolverToken {
    id<LKRTCAudioDeviceDelegate> delegate = self.delegate;
    if (delegate == nil) {
        if (routeReason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
            ASResolveRouteConfigurationChangeDisposition(
                notification,
                resolverToken,
                ASIOSRouteConfigurationChangeDispositionUninitialized
            );
        }
        return;
    }
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        BOOL initialized = self != nil && atomic_load_explicit(
            &self->_lifecycle.initialized,
            memory_order_acquire
        );
        if (!initialized) {
            if (routeReason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
                ASResolveRouteConfigurationChangeDisposition(
                    notification,
                    resolverToken,
                    ASIOSRouteConfigurationChangeDispositionUninitialized
                );
            }
            return;
        }
        os_unfair_lock_lock(&self->_expectedMicrophoneRouteChangeLock);
        BOOL supersededByNewerTransaction =
            ASShouldSuppressSupersededRouteConfigurationObservation(
                routeReason,
                notificationSequence,
                capturedTransactionIdentifier,
                self->_expectedMicrophoneRouteChangeState,
                self->_expectedMicrophoneRouteChangeTransactionIdentifier,
                self->_expectedMicrophoneRouteChangeObserverSequenceBaseline
            );
        os_unfair_lock_unlock(&self->_expectedMicrophoneRouteChangeLock);
        uint64_t currentSystemAudioGeneration = atomic_load_explicit(
            &self->_systemAudioGeneration,
            memory_order_acquire
        );
        BOOL retiredSystemAudioGeneration =
            ASShouldSuppressRetiredSystemAudioGenerationObservation(
                routeReason,
                capturedSystemAudioGeneration,
                currentSystemAudioGeneration
            );
        if (supersededByNewerTransaction
            || retiredSystemAudioGeneration) {
            if (routeReason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
                ASResolveRouteConfigurationChangeDisposition(
                    notification,
                    resolverToken,
                    ASIOSRouteConfigurationChangeDispositionStaleSuppressed
                );
            }
            return;
        }
        [self handleSystemEvent:ASSystemAudioEventRouteChanged
                    routeReason:routeReason];
        if (routeReason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
            ASResolveRouteConfigurationChangeDisposition(
                notification,
                resolverToken,
                ASIOSRouteConfigurationChangeDispositionGeneric
            );
        }
    }];
}

- (void)handleSystemEvent:(ASSystemAudioEvent)event
              routeReason:(AVAudioSessionRouteChangeReason)routeReason {
    switch (event) {
        case ASSystemAudioEventInterruptionBegan:
            _interrupted = YES;
            _recoveryRequired = YES;
            atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
            [self failClosedForSystemEventWithCode:ASIOSStereoPlayoutFailureInterruption
                                           message:@"Audio interruption began; playout is fail-closed."];
            return;

        case ASSystemAudioEventInterruptionEnded:
            _interrupted = NO;
            // Retire any stale installed policy before the application decides whether the
            // connected call may receive a fresh interruption-origin recovery authorization.
            [self revokeHostedCallAuthorization];
            _recoveryRequired = YES;
            atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
            [self failClosedForSystemEventWithCode:
                ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                                           message:@"Audio interruption ended; application-authorized recovery is required."];
            return;

        case ASSystemAudioEventRouteChanged: {
            AVAudioSession *session = [self currentAudioSession];
            if (routeReason == AVAudioSessionRouteChangeReasonCategoryChange) {
                BOOL hostedCallMode = [self hostedCallModeIsAuthorized];
                BOOL expected = [self sessionMatchesCurrentPolicy:session]
                    && (!hostedCallMode
                        || [self hasOutputRouteForSession:session]);
                if (expected) {
                    return;
                }
                _recoveryRequired = YES;
                atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
                [self failClosedForSystemEventWithCode:
                    ASIOSStereoPlayoutFailureUnexpectedCategoryChange
                                               message:[NSString stringWithFormat:
                                                   @"Unexpected audio category/mode/options change (%@/%@/%lu); playout is fail-closed.",
                                                   session.category,
                                                   session.mode,
                                                   (unsigned long)session.categoryOptions]];
                return;
            }

            _recoveryRequired = YES;
            atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
            if (routeReason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
                _explicitResumeRequired = YES;
                atomic_store_explicit(
                    &_lifecycle.explicitResumeRequired,
                    true,
                    memory_order_relaxed
                );
                [self failClosedForSystemEventWithCode:
                    ASIOSStereoPlayoutFailureRouteRequiresExplicitResume
                                               message:@"The prior output device became unavailable; explicit resume is required before speaker playout."];
                return;
            }
            NSString *routeMessage = [NSString stringWithFormat:
                @"Audio route changed (reason=%lu); application-authorized recovery is required.",
                (unsigned long)routeReason];
            if (routeReason
                    == AVAudioSessionRouteChangeReasonRouteConfigurationChange
                && [self expectedMicrophoneRouteChangeState]
                    == ASExpectedMicrophoneRouteChangeStateRejected) {
                NSString *routeSnapshot = [self
                    routeTransactionFailureSnapshotForPhase:
                        ASRouteTransactionDiagnosticPhaseObservationRejection
                    session:session
                    expectedTransactionIdentifier:0
                    requiredNotificationSequence:0];
                routeMessage = [routeMessage stringByAppendingFormat:
                    @" %@",
                    routeSnapshot];
            }
            [self failClosedForSystemEventWithCode:
                ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                                           message:routeMessage];
            return;
        }

        case ASSystemAudioEventMediaServicesReset:
            _interrupted = NO;
            _recoveryRequired = YES;
            atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
            [self failClosedForSystemEventWithCode:ASIOSStereoPlayoutFailureMediaServicesReset
                                           message:@"iOS media services reset; application-authorized recovery is required."];
            return;
    }
}

- (void)failClosedForSystemEventWithCode:(ASIOSStereoPlayoutFailureCode)code
                                  message:(NSString *)message {
    [self closeAndFenceRealtimeMicrophoneResources];
    if (_inputBusEnabled) {
        [self.delegate notifyAudioInputInterrupted];
    }
    if (_audioUnit != NULL || _playing) {
        [self.delegate notifyAudioOutputInterrupted];
    }
    [self failAndRollbackWithCode:code status:noErr message:message];
}

- (void)subscribeToSystemAudioNotifications {
    if (_notificationTokens != nil) {
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    id interruption = [center addObserverForName:AVAudioSessionInterruptionNotification
                                          object:AVAudioSession.sharedInstance
                                           queue:nil
                                      usingBlock:^(NSNotification *notification) {
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        NSNumber *typeValue = notification.userInfo[AVAudioSessionInterruptionTypeKey];
        if (self == nil || typeValue == nil) {
            return;
        }
        [self
            closeRealtimeRouteGatesAndRetireExpectedMicrophoneRouteChangeForSystemEvent];
        BOOL began = typeValue.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan;
        [self scheduleSystemEvent:(began
            ? ASSystemAudioEventInterruptionBegan
            : ASSystemAudioEventInterruptionEnded)
                      routeReason:AVAudioSessionRouteChangeReasonUnknown];
    }];
    id route = [center addObserverForName:AVAudioSessionRouteChangeNotification
                                   object:AVAudioSession.sharedInstance
                                    queue:nil
                               usingBlock:^(NSNotification *notification) {
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil) {
            return;
        }
        NSNumber *reasonValue = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
        AVAudioSessionRouteChangeReason reason = reasonValue == nil
            ? AVAudioSessionRouteChangeReasonUnknown
            : (AVAudioSessionRouteChangeReason)reasonValue.unsignedIntegerValue;
        ASRouteConfigurationChangeResolverToken resolverToken =
            ASInvalidRouteConfigurationChangeResolverToken;
        if (reason
            == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
            resolverToken = ASBeginRouteConfigurationChangeResolution(
                notification,
                (uintptr_t)(__bridge const void *)self
            );
            // Only the process-global current native device may classify this
            // exact reason-8 notification. A retiring device stays silent;
            // the dedicated observer still has bounded generic timeout.
            if (resolverToken.epoch == 0) {
                return;
            }
        }
        BOOL initialized = atomic_load_explicit(
            &self->_lifecycle.initialized,
            memory_order_acquire
        );
        if (!initialized) {
            if (reason
                == AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
                ASResolveRouteConfigurationChangeDisposition(
                    notification,
                    resolverToken,
                    ASIOSRouteConfigurationChangeDispositionUninitialized
                );
            }
            return;
        }
        [self enqueueExpectedMicrophoneRouteChangeNotification:notification
                                                       reason:reason
                                               resolverToken:resolverToken];
    }];
    id reset = [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                               object:AVAudioSession.sharedInstance
                                    queue:nil
                               usingBlock:^(__unused NSNotification *notification) {
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        [self
            closeRealtimeRouteGatesAndRetireExpectedMicrophoneRouteChangeForSystemEvent];
        [self scheduleSystemEvent:ASSystemAudioEventMediaServicesReset
                          routeReason:AVAudioSessionRouteChangeReasonUnknown];
    }];
    _notificationTokens = @[interruption, route, reset];
}

- (void)unsubscribeFromSystemAudioNotifications {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id token in _notificationTokens) {
        [center removeObserver:token];
    }
    _notificationTokens = nil;
}

@end
