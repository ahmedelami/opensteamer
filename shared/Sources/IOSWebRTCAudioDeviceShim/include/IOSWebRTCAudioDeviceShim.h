#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <LiveKitWebRTC/RTCAudioDevice.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Stable failure categories published by the output-only device. These codes deliberately avoid
/// exposing transient NSError domains to Swift/UI code while the adjacent message retains the
/// actionable native detail.
typedef NS_ENUM(NSInteger, ASIOSStereoPlayoutFailureCode) {
    ASIOSStereoPlayoutFailureNone = 0,
    ASIOSStereoPlayoutFailureSessionConfiguration = 1,
    ASIOSStereoPlayoutFailureSessionPreference = 2,
    ASIOSStereoPlayoutFailureSessionActivation = 3,
    ASIOSStereoPlayoutFailureMediaRouteInvariant = 4,
    ASIOSStereoPlayoutFailureAudioComponentUnavailable = 5,
    ASIOSStereoPlayoutFailureAudioUnitCreation = 6,
    ASIOSStereoPlayoutFailureMicrophoneBusDisable = 7,
    ASIOSStereoPlayoutFailureSpeakerBusEnable = 8,
    ASIOSStereoPlayoutFailureStreamFormat = 9,
    ASIOSStereoPlayoutFailureRenderCallback = 10,
    ASIOSStereoPlayoutFailureBusValidation = 11,
    ASIOSStereoPlayoutFailurePCMValidation = 12,
    ASIOSStereoPlayoutFailureAudioUnitInitialization = 13,
    ASIOSStereoPlayoutFailureAudioUnitStart = 14,
    ASIOSStereoPlayoutFailureAudioUnitStop = 15,
    ASIOSStereoPlayoutFailureSessionDeactivation = 16,
    ASIOSStereoPlayoutFailureInterruption = 17,
    ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired = 18,
    ASIOSStereoPlayoutFailureRouteRequiresExplicitResume = 19,
    ASIOSStereoPlayoutFailureUnexpectedCategoryChange = 20,
    ASIOSStereoPlayoutFailureMediaServicesReset = 21,
    ASIOSStereoPlayoutFailureMicrophoneStreamFormat = 22,
    ASIOSStereoPlayoutFailureMicrophoneInputCallback = 23,
    ASIOSStereoPlayoutFailureMicrophoneBufferAllocation = 24,
    ASIOSStereoPlayoutFailureMicrophoneDelivery = 25,
};

/// Exact source of one hosted-call output-only policy. Unspecified is never admissible.
typedef NS_ENUM(NSInteger, ASIOSHostedCallPlayoutOrigin) {
    ASIOSHostedCallPlayoutOriginUnspecified = 0,
    ASIOSHostedCallPlayoutOriginInterruption = 1,
    ASIOSHostedCallPlayoutOriginStartupConnectedCall = 2,
};

/// A lock-free snapshot of counters written by the RemoteIO render callback plus atomically
/// mirrored device lifecycle state.
typedef struct ASIOSStereoPlayoutDiagnostics {
    bool initialized;
    bool playoutInitialized;
    bool playing;
    bool sessionActive;
    bool ownsSessionActivation;
    bool remoteIOCreated;
    bool inputBusEnabled;
    bool outputBusEnabled;
    bool recoveryRequired;
    bool explicitResumeRequired;
    bool categoryIsMediaPlayback;
    bool categoryIsMediaPlayAndRecord;
    bool modeIsDefault;
    double sampleRate;
    double outputIOBufferDuration;
    NSInteger outputChannelCount;
    uint32_t audioUnitSubType;
    ASIOSStereoPlayoutFailureCode failureCode;
    int32_t lastLifecycleStatus;
    uint64_t playoutCallbackCount;
    uint64_t playoutFrameCount;
    uint64_t playoutFailureCount;
    uint64_t playoutPCMSampleCount;
    uint64_t playoutPCMNonzeroSampleCount;
    uint64_t playoutPCMAbsoluteSampleSum;
    uint64_t playoutPCMLeftAbsoluteSampleSum;
    uint64_t playoutPCMRightAbsoluteSampleSum;
    uint64_t playoutPCMStereoDifferenceAbsoluteSampleSum;
    uint64_t playoutPCMClippedSampleCount;
    uint64_t playoutExplicitSilenceCallbackCount;
    uint64_t playoutCallbackGapViolationCount;
    uint64_t playoutMaximumCallbackGapNanoseconds;
    uint64_t playoutNearSilenceCallbackCount;
    uint64_t playoutCurrentConsecutiveNearSilenceFrameCount;
    uint64_t playoutMaximumConsecutiveNearSilenceFrameCount;
    uint64_t playoutPCMLeftZeroCrossingCount;
    uint64_t playoutPCMRightZeroCrossingCount;
    uint64_t playoutPCMEnvelopeTransitionCount;
    uint64_t playoutPCMShapeAnomalyCallbackCount;
    uint64_t playoutPCMBoundaryDiscontinuityCallbackCount;
    uint32_t playoutLastCallbackMeanMagnitude;
    uint64_t unexpectedRecordingRequestCount;
    uint64_t recoveryRequestCount;
    uint64_t recoveryAuthorizationRejectionCount;
    uint64_t recoveryRebuildCount;
    uint32_t lastPlayoutFrameCount;
    uint32_t lastPlayoutPeakMagnitude;
    int32_t lastPlayoutStatus;
    bool microphoneDeviceGateClosedAndDrained;
    bool microphoneAuthorizationGatePublished;
    uint64_t microphoneRecordingGeneration;
    uint64_t approvedMicrophoneRecordingGeneration;
    uint64_t microphoneRealtimeAdmissionCount;
    uint64_t microphoneDeliveryCallbackCount;
    uint64_t microphoneDeliveredFrameCount;
    bool categoryOptionsAreEmpty;
    bool routeSharingPolicyIsDefault;
    bool categoryOptionsAreMixWithOthers;
    bool hasOutputRoute;
    bool hostedCallMode;
    bool hostedCallAuthorizationValid;
    bool hostedCallRecoveryPending;
    ASIOSHostedCallPlayoutOrigin hostedCallOrigin;
    uint64_t systemAudioGeneration;
    uint64_t hostedCallAuthorizationGeneration;
} ASIOSStereoPlayoutDiagnostics;

/// Persistent, synchronously revocable ownership for one user-authorized
/// iPhone microphone generation.
@interface ASIOSMicrophoneAuthorization : NSObject

@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly) uint64_t microphoneRecordingGeneration;

- (void)revoke;

#if DEBUG
- (BOOL)debugBeginRealtimeAdmissionForTesting;
- (void)debugEndRealtimeAdmissionForTesting;
- (void)waitForRealtimeGateClosureForTesting;
- (void)debugSetMicrophoneRecordingGenerationForTesting:
    (uint64_t)recordingGeneration
    NS_SWIFT_NAME(debugSetMicrophoneRecordingGenerationForTesting(_:));
- (BOOL)performIfValidForTesting:(NS_NOESCAPE dispatch_block_t)operation;
#endif

@end

/// A synchronously revocable, one-shot gate for one explicit playout-recovery attempt.
///
/// Revocation and the authorized native operation share one lock. Once `revoke` returns, a
/// recovery block that was queued earlier can no longer begin or continue through this gate. A
/// successful authorized operation consumes the gate before releasing the lock.
@interface ASIOSStereoPlayoutRecoveryAuthorization : NSObject

@property(nonatomic, readonly, getter=isValid) BOOL valid;

- (void)revoke;

/// Runs `operation` only while this authorization still owns the recovery boundary. The shared
/// lock remains held until the operation returns, making a concurrent `revoke` a synchronous
/// barrier. Native recovery code uses this immediately around its final side effects.
- (BOOL)performIfValid:(NS_NOESCAPE dispatch_block_t)operation;

@end

/// Persistent policy ownership plus one recovery claim for a connected hosted CallKit call.
///
/// `valid` remains true after the recovery claim is consumed so the rebuilt RemoteIO can continue
/// to prove that its exact hosted-call policy is live. Revocation shares the native operation lock,
/// then synchronously retires any installed native policy before returning.
@interface ASIOSHostedCallPlayoutAuthorization : NSObject

@property(nonatomic, readonly) NSUUID *policyIdentifier;
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly, getter=isRecoveryPending) BOOL recoveryPending;
@property(nonatomic, readonly) ASIOSHostedCallPlayoutOrigin origin;
@property(nonatomic, readonly) uint64_t systemAudioGeneration;

- (instancetype)initWithPolicyIdentifier:(NSUUID *)policyIdentifier
                                  origin:(ASIOSHostedCallPlayoutOrigin)origin
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Synchronously invalidates the policy and fences any authorized native recovery operation.
- (void)revoke;

#if DEBUG
/// Consumes the one-shot recovery claim and runs `operation` only while the policy remains valid.
- (BOOL)performRecoveryIfValidForTesting:(NS_NOESCAPE dispatch_block_t)operation;

/// Consumes the one-shot claim only after atomically installing the caller-provided revocation
/// handler and nonzero system-audio generation while the native recovery-operation lock is held.
/// Invalid, revoked, already-consumed, zero-generation, and duplicate installation attempts fail.
- (BOOL)performRecoveryIfValidForTestingWithSystemAudioGeneration:(uint64_t)systemAudioGeneration
                                                revocationHandler:(dispatch_block_t)revocationHandler
                                                         operation:(NS_NOESCAPE dispatch_block_t)operation
    NS_SWIFT_NAME(performRecoveryIfValidForTesting(systemAudioGeneration:revocationHandler:operation:));
#endif

@end

#if DEBUG
typedef struct ASIOSStereoPlayoutPublicationSnapshot {
    uint64_t callbackCount;
    uint64_t frameCount;
    uint64_t failureCount;
    uint64_t pcmSampleCount;
    uint64_t pcmNonzeroSampleCount;
    uint64_t pcmAbsoluteSampleSum;
    uint64_t pcmLeftAbsoluteSampleSum;
    uint64_t pcmRightAbsoluteSampleSum;
    uint64_t pcmStereoDifferenceAbsoluteSampleSum;
    uint64_t pcmClippedSampleCount;
    uint64_t explicitSilenceCallbackCount;
    uint64_t callbackGapViolationCount;
    uint64_t maximumCallbackGapNanoseconds;
    uint64_t nearSilenceCallbackCount;
    uint64_t currentConsecutiveNearSilenceFrameCount;
    uint64_t maximumConsecutiveNearSilenceFrameCount;
    uint64_t pcmLeftZeroCrossingCount;
    uint64_t pcmRightZeroCrossingCount;
    uint64_t pcmEnvelopeTransitionCount;
    uint64_t pcmShapeAnomalyCallbackCount;
    uint64_t pcmBoundaryDiscontinuityCallbackCount;
    uint32_t lastCallbackMeanMagnitude;
    uint32_t lastFrameCount;
    uint32_t lastPeakMagnitude;
    int32_t lastStatus;
} ASIOSStereoPlayoutPublicationSnapshot;

/// Invokes the production callback-publication primitive without touching audio hardware.
@interface ASIOSStereoPlayoutPublicationTestHarness : NSObject

@property(nonatomic, readonly) ASIOSStereoPlayoutPublicationSnapshot prePublicationSnapshot;
@property(nonatomic, readonly) ASIOSStereoPlayoutPublicationSnapshot snapshot;

- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                status:(int32_t)status;
- (void)analyzePCM16Samples:(NSData *)samples
             outputIsSilence:(BOOL)outputIsSilence;
- (void)recordSuccessfulCallbackAtMonotonicTimeNanoseconds:(uint64_t)nanoseconds
    NS_SWIFT_NAME(recordSuccessfulCallback(atMonotonicTimeNanoseconds:));
- (void)markRecoveryBoundary;

@end

/// Drives the real queued recovery boundary without starting playout or touching audio hardware.
@interface ASIOSStereoPlayoutRecoveryTestHarness : NSObject

@property(nonatomic, readonly) ASIOSStereoPlayoutDiagnostics diagnostics;
@property(nonatomic, readonly) NSUInteger queuedOperationCount;
/// Number of invocations of the production audio-policy configuration boundary. The deterministic
/// harness records the exact inputs to that operation but does not create a hardware AudioUnit.
@property(nonatomic, readonly) NSUInteger configurationOperationCount;
@property(nonatomic, readonly, nullable) NSString *lastConfiguredCategory;
@property(nonatomic, readonly, nullable) NSString *lastConfiguredMode;
@property(nonatomic, readonly) NSInteger lastConfiguredRouteSharingPolicy;
@property(nonatomic, readonly) NSUInteger lastConfiguredCategoryOptions;
@property(nonatomic, readonly) BOOL lastConfiguredInputBusEnabled;
@property(nonatomic, readonly) BOOL lastConfiguredOutputBusEnabled;
@property(nonatomic, readonly) AudioStreamBasicDescription lastConfiguredOutputStreamFormat;
@property(nonatomic, readonly, nullable) NSUUID *hostedCallPolicyIdentifier;

- (void)debugInstallMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization;
- (BOOL)setMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization
    NS_SWIFT_NAME(setMicrophoneAuthorizationForTesting(_:));
- (BOOL)debugPublishCurrentMicrophoneAuthorizationForTesting;
- (BOOL)debugBeginRealtimeAdmissionForTesting;
- (void)debugEndRealtimeAdmissionForTesting;
- (void)debugCloseAndFenceRealtimeGateForTesting;
- (void)waitForRealtimeGateClosureForTesting;
- (BOOL)debugTerminateForTesting;
- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                 status:(int32_t)status;
- (void)queueRecoveryWithAuthorization:
    (ASIOSStereoPlayoutRecoveryAuthorization *)authorization
    NS_SWIFT_NAME(queueRecovery(authorization:));
- (void)queueHostedCallRecoveryWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
    NS_SWIFT_NAME(queueHostedCallRecovery(authorization:));
- (BOOL)armStartupConnectedCallPlayoutWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
    NS_SWIFT_NAME(armStartupConnectedCallPlayout(authorization:));
- (BOOL)debugStartPlayoutForTesting;
- (void)debugMarkInterruptedFailClosedForTesting;
- (void)debugMarkInterruptionEndedFailClosedForTesting;
- (void)debugMarkHealthyPlayoutForTesting;
- (void)debugMarkRouteLossForTesting;
- (void)debugAdvanceSystemAudioGenerationForTesting;
- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available;
- (void)debugFailNextHostedCallActivationForTesting;
- (BOOL)runNextQueuedOperation;

@end
#endif

/// Conditional-duplex WebRTC audio device for iPhone/iPad viewers.
///
/// It remains output-only until the app supplies a current microphone
/// authorization. Both directions use the same RemoteIO instance.
@interface ASIOSStereoPlayoutAudioDevice : NSObject <LKRTCAudioDevice>

@property(nonatomic, readonly) ASIOSStereoPlayoutDiagnostics diagnostics;
@property(atomic, copy, readonly, nullable) NSString *lastLifecycleFailureMessage;

/// Explicitly authorizes a safe rebuild after the application has applied its interruption/route
/// policy and recovered the manual WebRTC audio gate. System notifications only fail closed; they
/// never call this method implicitly. It may be called from any thread and mutates the device on
/// WebRTC's ADM thread. The exact attempt authorization is checked again inside that queued native
/// operation immediately around the recovery side effects.
- (void)requestPlayoutRecoveryWithAuthorization:
    (ASIOSStereoPlayoutRecoveryAuthorization *)authorization
    NS_SWIFT_NAME(requestPlayoutRecovery(authorization:));

/// Authorizes exactly one output-only rebuild for an interruption-origin hosted-call policy.
/// Active interruptions remain fail-closed; the app may submit this only after interruption-ended
/// and observed native quiescence.
- (void)requestHostedCallPlayoutRecoveryWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
    NS_SWIFT_NAME(requestHostedCallPlayoutRecovery(authorization:));

/// Synchronously arms startup-connected-call ownership while the WebRTC manual audio gate remains
/// closed. The operation performs no AVAudioSession configuration or activation and creates no
/// RemoteIO. First StartPlayout builds under the consumed exact hosted policy.
- (BOOL)armStartupConnectedCallPlayoutWithAuthorization:
    (ASIOSHostedCallPlayoutAuthorization *)authorization
    NS_SWIFT_NAME(armStartupConnectedCallPlayout(authorization:));

/// Synchronously applies or revokes the current microphone generation on
/// WebRTC's ADM queue. A nonnull authorization stages and starts the complete
/// playAndRecord/default RemoteIO topology, but leaves both realtime
/// publication gates closed. A nil authorization synchronously retires any
/// staged or approved generation and restores playback/default.
- (BOOL)setMicrophoneAuthorization:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization
    NS_SWIFT_NAME(setMicrophoneAuthorization(_:));

/// Builds and starts the complete authorized duplex topology while leaving
/// microphone PCM publication closed. Returns the exact nonzero staged
/// recording generation, or zero after a fail-closed rejection.
- (uint64_t)stageMicrophoneAuthorization:
    (ASIOSMicrophoneAuthorization *)authorization
    NS_SWIFT_NAME(stageMicrophoneAuthorization(_:));

/// Opens realtime microphone publication only when `authorization` still owns
/// the exact current, unapproved staged generation. Approval is synchronous and
/// one-shot for that generation. Zero, stale, wrong, revoked, and duplicate
/// generations fail closed.
- (BOOL)approveStagedMicrophoneAuthorization:
            (ASIOSMicrophoneAuthorization *)authorization
                           recordingGeneration:(uint64_t)recordingGeneration
    NS_SWIFT_NAME(approveStagedMicrophoneAuthorization(_:recordingGeneration:));

#if DEBUG
- (void)debugInstallMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization;
- (BOOL)debugPublishCurrentMicrophoneAuthorizationForTesting;
- (BOOL)debugBeginRealtimeAdmissionForTesting;
- (void)debugEndRealtimeAdmissionForTesting;
- (void)debugCloseAndFenceRealtimeGateForTesting;
- (void)waitForRealtimeGateClosureForTesting;
- (BOOL)debugTerminateForTesting;
#endif

@end

NS_ASSUME_NONNULL_END
