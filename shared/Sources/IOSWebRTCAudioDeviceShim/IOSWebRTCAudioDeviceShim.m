#import "IOSWebRTCAudioDeviceShim.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <limits.h>
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
/// `setActive:NO` after a newer peer has become the process's audio owner.
static os_unfair_lock ASSessionOwnershipLock = OS_UNFAIR_LOCK_INIT;
static uint64_t ASNextSessionOwnershipToken = 0;
static uint64_t ASCurrentSessionOwnershipToken = 0;

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

static ASAudioPolicyConfiguration ASMakeAudioPolicyConfiguration(
    BOOL hostedCallMode,
    BOOL microphoneEnabled,
    AudioStreamBasicDescription outputStreamFormat
) {
    return (ASAudioPolicyConfiguration) {
        .categoryOptions = hostedCallMode
            ? AVAudioSessionCategoryOptionMixWithOthers
            : 0,
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
}
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
    ASRealtimeGate _realtimeMicrophoneDeviceGate;
    atomic_ulong _realtimeMicrophoneAuthorizationGate;
    atomic_uint_fast64_t _realtimeMicrophoneRecordingGeneration;
    atomic_uint_fast64_t _realtimeApprovedMicrophoneRecordingGeneration;
    AudioComponentInstance _audioUnit;
    int16_t *_recordingSamples;
    UInt32 _recordingSampleCapacity;
    BOOL _recording;
@private
    ASLifecycleDiagnostics _lifecycle;
    atomic_uint_fast64_t _systemAudioGeneration;
    AudioStreamBasicDescription _streamFormat;
    AudioStreamBasicDescription _inputStreamFormat;
    BOOL _initialized;
    BOOL _playoutInitialized;
    BOOL _playing;
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
    NSArray<id> *_notificationTokens;
    ASIOSMicrophoneAuthorization *_microphoneAuthorization;
    uint64_t _microphoneRecordingGenerationCounter;
    atomic_uint_fast64_t _microphoneApprovalConsumedGeneration;
    uint64_t _hostedCallAuthorizationGeneration;
    NSUUID *_hostedCallPolicyIdentifier;
    ASIOSHostedCallPlayoutAuthorization *_hostedCallAuthorization;
    ASIOSHostedCallPlayoutAuthorization *_hostedCallRecoveryInProgressAuthorization;
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
#endif
}
@property(atomic, strong, nullable) id<LKRTCAudioDeviceDelegate> delegate;
@property(atomic, copy, readwrite, nullable) NSString *lastLifecycleFailureMessage;
- (void)closeAndFenceRealtimeMicrophoneResources;
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
- (BOOL)activateOwnedSession:(AVAudioSession *)session
                       error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deactivateOwnedSessionWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)ownsCurrentSessionActivation;
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
- (void)debugFailNextHostedCallActivationForTesting;
#endif
- (void)scheduleSystemEvent:(ASSystemAudioEvent)event
                routeReason:(AVAudioSessionRouteChangeReason)routeReason;
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

@implementation ASIOSStereoPlayoutRecoveryAuthorization

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
        atomic_init(&_valid, true);
    }
    return self;
}

- (BOOL)isValid {
    // Status polling can occur on MainActor while the native ADM thread performs a rebuild.
    // The ownership lock remains the revocation barrier, but observing pending/completed state
    // must never block the app UI behind AVAudioSession or RemoteIO work.
    return atomic_load_explicit(&_valid, memory_order_acquire);
}

- (void)revoke {
    os_unfair_lock_lock(&_lock);
    atomic_store_explicit(&_valid, false, memory_order_release);
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)performIfValid:(NS_NOESCAPE dispatch_block_t)operation {
    os_unfair_lock_lock(&_lock);
    if (!atomic_load_explicit(&_valid, memory_order_acquire)) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    operation();
    atomic_store_explicit(&_valid, false, memory_order_release);
    os_unfair_lock_unlock(&_lock);
    return YES;
}

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

@interface ASIOSStereoPlayoutRecoveryTestHarness ()
@property(nonatomic, strong) ASIOSStereoPlayoutAudioDevice *device;
@property(nonatomic, strong) ASIOSStereoPlayoutRecoveryHarnessDelegate *delegate;
@end

@implementation ASIOSStereoPlayoutRecoveryTestHarness

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _device = [[ASIOSStereoPlayoutAudioDevice alloc] init];
    _delegate = [[ASIOSStereoPlayoutRecoveryHarnessDelegate alloc] init];
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

- (void)debugAdvanceSystemAudioGenerationForTesting {
    [self.device debugAdvanceSystemAudioGenerationForTesting];
}

- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available {
    [self.device debugSetOutputRouteAvailableForTesting:available];
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
    ASInitializeRealtimeGateClosed(&_realtimeMicrophoneDeviceGate);
    atomic_init(&_realtimeMicrophoneAuthorizationGate, 0);
    atomic_init(&_realtimeMicrophoneRecordingGeneration, 0);
    atomic_init(&_realtimeApprovedMicrophoneRecordingGeneration, 0);
    atomic_init(&_microphoneApprovalConsumedGeneration, 0);
    atomic_init(&_systemAudioGeneration, 0);
    _microphoneRecordingGenerationCounter = 0;
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
    atomic_store_explicit(&_lifecycle.initialized, true, memory_order_relaxed);
#if DEBUG
    if (!_debugRecoveryHarnessMode) {
        [self subscribeToSystemAudioNotifications];
    }
#else
    [self subscribeToSystemAudioNotifications];
#endif
    return YES;
}

- (BOOL)terminateDevice {
    _wantsPlayout = NO;
    _wantsRecording = NO;
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
    _initialized = NO;
    _interrupted = NO;
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    _isRebuilding = NO;
    _recording = NO;
    atomic_store_explicit(&_lifecycle.playoutInitialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.initialized, false, memory_order_relaxed);
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
    OSStatus status = AudioOutputUnitStart(_audioUnit);
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureAudioUnitStart
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"RemoteIO start failed (%d).",
                                  (int)status]];
        return NO;
    }
    _playing = YES;
    atomic_store_explicit(&_lifecycle.playing, true, memory_order_relaxed);
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
    _debugOwnsSessionActivation = NO;
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
        [authorization revoke];
        return;
    }
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

        __block BOOL accepted = NO;
        BOOL authorized = [authorization performIfValid:^{
            if ([self hostedCallModeIsAuthorized]) {
                [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                                 status:noErr
                                message:@"Ordinary recovery cannot replace a live hosted-call policy."];
                return;
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
                    accepted = YES;
                    return;
                }
#endif
                accepted = [self startPlayout];
                return;
            }
            if (self->_interrupted) {
                [self publishFailureCode:ASIOSStereoPlayoutFailureInterruption
                                 status:noErr
                                message:@"Audio remains interrupted; explicit recovery cannot start yet."];
                return;
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
            accepted = [self rebuildAfterExplicitRecovery];
        }];
        if (!authorized || !accepted) {
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
    BOOL remainedValid = [authorization performWhileValid:^{
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
        if (!ASRealtimeGateIsClosedAndDrained(
                &self->_realtimeMicrophoneDeviceGate)) {
            ASFailRealtimeGateInvariant();
        }
        if (atomic_load_explicit(
                &self->_realtimeMicrophoneAuthorizationGate,
                memory_order_acquire
            ) != 0) {
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
        ASResetClosedRealtimeGate(&self->_realtimeMicrophoneDeviceGate);
        published = YES;
    }];
    BOOL approved = remainedValid && published;
    if (!approved) {
        [self closeAndFenceRealtimeMicrophoneResources];
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
    [self closeAndFenceRealtimeMicrophoneResources];
    [self clearCurrentMicrophoneRecordingGeneration];
    NSError *error = nil;
    AVAudioSession *session = [self currentAudioSession];
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
        (void)[session
            setPreferredOutputNumberOfChannels:ASOutputChannelCount
                                         error:nil];
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
        if (![session
                setPreferredOutputNumberOfChannels:ASOutputChannelCount
                                             error:&error]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred stereo-output request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        }
        if (microphoneEnabled
            && ![session
                setPreferredInputNumberOfChannels:ASInputChannelCount
                                            error:&error]) {
            [self failAndRollbackWithCode:
                ASIOSStereoPlayoutFailureSessionPreference
                                   status:(int32_t)error.code
                                  message:[NSString stringWithFormat:
                                      @"Preferred mono-input request failed: %@. %@",
                                      error.localizedDescription ?: @"unknown error",
                                      ASAudioSessionDiagnosticDescription(session)]];
            return NO;
        }
    }
    if (![self activateOwnedSession:session error:&error]) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSessionActivation
                               status:(int32_t)error.code
                              message:[NSString stringWithFormat:
                                  @"Media playback audio-session activation failed: %@. %@",
                                  error.localizedDescription ?: @"unknown error",
                                  ASAudioSessionDiagnosticDescription(session)]];
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
    _playoutInitialized = YES;
    atomic_store_explicit(&_lifecycle.playoutInitialized, true, memory_order_relaxed);
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    [self clearLifecycleFailure];
    return YES;
}

- (BOOL)activateOwnedSession:(AVAudioSession *)session error:(NSError **)error {
    NSError *activationError = nil;
    BOOL activated = NO;
    os_unfair_lock_lock(&ASSessionOwnershipLock);
    activated = [session setActive:YES error:&activationError];
    if (activated) {
        ASNextSessionOwnershipToken += 1;
        if (ASNextSessionOwnershipToken == 0) {
            ASNextSessionOwnershipToken = 1;
        }
        _sessionOwnershipToken = ASNextSessionOwnershipToken;
        ASCurrentSessionOwnershipToken = _sessionOwnershipToken;
    }
    os_unfair_lock_unlock(&ASSessionOwnershipLock);

    if (activated) {
        _sessionActive = YES;
        atomic_store_explicit(&_lifecycle.sessionActive, true, memory_order_relaxed);
    }
    if (error != NULL) {
        *error = activationError;
    }
    return activated;
}

- (BOOL)deactivateOwnedSessionWithError:(NSError **)error {
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
    [self closeAndFenceRealtimeMicrophoneResources];
    [self clearCurrentMicrophoneRecordingGeneration];
    OSStatus firstFailure = noErr;
    if (_audioUnit != NULL) {
        if (_playing) {
            OSStatus status = AudioOutputUnitStop(_audioUnit);
            if (status != noErr) {
                firstFailure = status;
            }
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
    _playing = NO;
    _playoutInitialized = NO;
    _inputBusEnabled = NO;
    _outputBusEnabled = NO;
    _audioUnitSubType = 0;
#if DEBUG
    if (_debugRecoveryHarnessMode) {
        _debugHealthyPlayoutForTesting = NO;
    }
#endif
    atomic_store_explicit(&_lifecycle.playing, false, memory_order_relaxed);
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
            [self failClosedForSystemEventWithCode:
                ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                                           message:[NSString stringWithFormat:
                                               @"Audio route changed (reason=%lu); application-authorized recovery is required.",
                                               (unsigned long)routeReason]];
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
        NSNumber *reasonValue = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
        AVAudioSessionRouteChangeReason reason = reasonValue == nil
            ? AVAudioSessionRouteChangeReasonUnknown
            : (AVAudioSessionRouteChangeReason)reasonValue.unsignedIntegerValue;
        [weakSelf scheduleSystemEvent:ASSystemAudioEventRouteChanged routeReason:reason];
    }];
    id reset = [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                               object:AVAudioSession.sharedInstance
                                    queue:nil
                               usingBlock:^(__unused NSNotification *notification) {
        [weakSelf scheduleSystemEvent:ASSystemAudioEventMediaServicesReset
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
