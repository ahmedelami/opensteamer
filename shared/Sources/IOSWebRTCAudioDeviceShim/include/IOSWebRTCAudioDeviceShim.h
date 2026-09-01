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

/// Exact fail-closed outcome of one synchronous staged microphone request. This is deliberately
/// separate from the broader lifecycle failure code: callers use it to distinguish one safe
/// audio-recovery retry from call/privacy gates and terminal authorization failures.
typedef NS_ENUM(NSInteger, ASIOSMicrophoneStageFailureReason) {
    ASIOSMicrophoneStageFailureNone = 0,
    ASIOSMicrophoneStageFailureDelegateUnavailable = 1,
    ASIOSMicrophoneStageFailureDeviceNotInitialized = 2,
    ASIOSMicrophoneStageFailurePlayoutNotReady = 3,
    ASIOSMicrophoneStageFailureNativeRecoveryRequired = 4,
    ASIOSMicrophoneStageFailureTopologyRebuildFailed = 5,
    ASIOSMicrophoneStageFailureTopologyStillNotStaged = 6,
    ASIOSMicrophoneStageFailureHostedCall = 7,
    ASIOSMicrophoneStageFailureInterrupted = 8,
    ASIOSMicrophoneStageFailureExplicitResumeRequired = 9,
    ASIOSMicrophoneStageFailureAuthorizationInvalid = 10,
    ASIOSMicrophoneStageFailureRecordingGenerationBindFailed = 11,
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
    /// Privacy-minimal live capture-source proof; no port name or UID leaves native code.
    bool captureRouteIsBuiltInMicrophone;
    /// Nonzero exact native route-publication epoch; never a route name or identifier.
    uint64_t captureRouteProofGeneration;
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
    bool categoryOptionsAreIPhoneMicrophoneRouting;
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
@property(nonatomic, readonly)
    ASIOSMicrophoneStageFailureReason microphoneStageFailureReason;

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
typedef NS_ENUM(NSInteger, ASIOSStereoPlayoutRecoveryTerminalOutcome) {
    ASIOSStereoPlayoutRecoveryTerminalOutcomePending = 0,
    ASIOSStereoPlayoutRecoveryTerminalOutcomeAccepted = 1,
    ASIOSStereoPlayoutRecoveryTerminalOutcomeRejected = 2,
    ASIOSStereoPlayoutRecoveryTerminalOutcomeRevoked = 3,
};

@interface ASIOSStereoPlayoutRecoveryAuthorization : NSObject

@property(nonatomic, readonly, getter=isValid) BOOL valid;
/// Immutable nonzero identity for this exact authorization instance.
@property(nonatomic, readonly) uint64_t generation;
/// Zero while pending; exactly `generation` after a terminal outcome is published.
@property(nonatomic, readonly) uint64_t terminalGeneration;
@property(nonatomic, readonly)
    ASIOSStereoPlayoutRecoveryTerminalOutcome terminalOutcome;

- (void)revoke;

/// Runs `operation` only while this authorization still owns the recovery boundary. The shared
/// lock remains held until the operation returns, making a concurrent `revoke` a synchronous
/// barrier. Native recovery code uses this immediately around its final side effects.
- (BOOL)performIfValid:(NS_NOESCAPE dispatch_block_t)operation;

#if DEBUG
/// Deterministically publishes a native rejection without executing recovery side effects.
- (BOOL)debugRejectIfValidForTesting;
#endif

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

/// Production classification result for AVAudioSession route-change evidence. The deterministic
/// harness below exposes the same classifier in DEBUG builds, but the native release path also
/// consumes this type while deciding whether to retain or retire a route transaction.
typedef NS_ENUM(NSInteger, ASIOSExpectedRouteChangeDisposition) {
    ASIOSExpectedRouteChangeDispositionUnrelated = 0,
    ASIOSExpectedRouteChangeDispositionConsume = 1,
    ASIOSExpectedRouteChangeDispositionRejectTransaction = 2,
};

/// Final native ownership of one exact reason-8 AVAudioSession notification.
///
/// The Swift lifecycle observer cannot infer this from the reason alone: NotificationCenter may
/// invoke it before or after the native audio-device observer. The native observer therefore
/// resolves the exact NSNotification object and this dedicated observer waits asynchronously for
/// that disposition. Only the first three outcomes suppress Swift's generic route recovery.
typedef NS_ENUM(NSInteger, ASIOSRouteConfigurationChangeDisposition) {
    ASIOSRouteConfigurationChangeDispositionConsumed = 0,
    ASIOSRouteConfigurationChangeDispositionLiveRejectionOwnedByWaiter = 1,
    ASIOSRouteConfigurationChangeDispositionStaleSuppressed = 2,
    ASIOSRouteConfigurationChangeDispositionGeneric = 3,
    ASIOSRouteConfigurationChangeDispositionUninitialized = 4,
    ASIOSRouteConfigurationChangeDispositionTimedOut = 5,
};

typedef void (^ASIOSRouteConfigurationChangeDispositionHandler)(
    ASIOSRouteConfigurationChangeDisposition disposition
);

typedef void (^ASIOSRouteConfigurationChangeObservationHandler)(
    ASIOSRouteConfigurationChangeDisposition disposition,
    uint64_t notificationSequence,
    uint64_t audioPolicyEpoch
);

/// Observes reason-8 notifications without losing their Objective-C object identity. Waiting is
/// nonblocking so a Swift-first NotificationCenter callback cannot prevent the later native
/// observer from running. The handler may be invoked on an arbitrary non-realtime queue.
@interface ASIOSRouteConfigurationChangeObserver : NSObject

/// Latest nonzero reason-8 ingress sequence observed by this exact observer instance.
@property(nonatomic, readonly) uint64_t latestNotificationSequence;

- (instancetype)initWithTimeout:(NSTimeInterval)timeout
                         handler:
                             (ASIOSRouteConfigurationChangeObservationHandler)handler
    NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(timeout:handler:));
- (instancetype)init NS_UNAVAILABLE;

/// Updates the application policy epoch captured by subsequent reason-8 ingress.
- (void)updateAudioPolicyEpoch:(uint64_t)audioPolicyEpoch
    NS_SWIFT_NAME(updateAudioPolicyEpoch(_:));

/// Stops new observations and fences every delayed resolution already waiting for native code.
- (void)invalidate;

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

typedef NS_ENUM(NSInteger, ASIOSExpectedRouteChangeTestScenario) {
    ASIOSExpectedRouteChangeTestScenarioPendingActivation = 0,
    ASIOSExpectedRouteChangeTestScenarioPendingBound = 1,
    ASIOSExpectedRouteChangeTestScenarioPendingCategory = 2,
    ASIOSExpectedRouteChangeTestScenarioPendingOverride = 3,
    ASIOSExpectedRouteChangeTestScenarioPendingWrongPreviousRoute = 4,
    ASIOSExpectedRouteChangeTestScenarioPendingWrongGeneration = 5,
    ASIOSExpectedRouteChangeTestScenarioPendingWrongOwnership = 6,
    ASIOSExpectedRouteChangeTestScenarioConvergedDuplicate = 7,
    ASIOSExpectedRouteChangeTestScenarioConvergedChangedRoute = 8,
    ASIOSExpectedRouteChangeTestScenarioConvergedRecoveryRequired = 9,
    ASIOSExpectedRouteChangeTestScenarioConvergedExpired = 10,
    ASIOSExpectedRouteChangeTestScenarioPendingCoalescedSkippedIntermediate = 11,
    ASIOSExpectedRouteChangeTestScenarioPendingExpired = 12,
    ASIOSExpectedRouteChangeTestScenarioPendingSequenceNotAdvanced = 13,
    ASIOSExpectedRouteChangeTestScenarioPendingWrongSystemGeneration = 14,
    ASIOSExpectedRouteChangeTestScenarioPendingWrongPolicy = 15,
    ASIOSExpectedRouteChangeTestScenarioPendingMissingFingerprint = 16,
    ASIOSExpectedRouteChangeTestScenarioConvergedWrongOwnership = 17,
    ASIOSExpectedRouteChangeTestScenarioConvergedInactive = 18,
    ASIOSExpectedRouteChangeTestScenarioConvergedOutputMissing = 19,
    ASIOSExpectedRouteChangeTestScenarioConvergedChannelMismatch = 20,
    ASIOSExpectedRouteChangeTestScenarioConvergedTargetMismatch = 21,
    ASIOSExpectedRouteChangeTestScenarioConvergedPreferredMismatch = 22,
    ASIOSExpectedRouteChangeTestScenarioConvergedWrongSystemGeneration = 23,
    ASIOSExpectedRouteChangeTestScenarioConvergedWrongGeneration = 24,
    ASIOSExpectedRouteChangeTestScenarioConvergedPreviousUnseen = 25,
    ASIOSExpectedRouteChangeTestScenarioConvergedExplicitResumeRequired = 26,
    ASIOSExpectedRouteChangeTestScenarioPreparedExact = 27,
    ASIOSExpectedRouteChangeTestScenarioPreparedChangedRoute = 28,
    ASIOSExpectedRouteChangeTestScenarioStartingChangedRoute = 29,
    ASIOSExpectedRouteChangeTestScenarioStartingWrongOwnership = 30,
    ASIOSExpectedRouteChangeTestScenarioStartingRecoveryRequired = 31,
    ASIOSExpectedRouteChangeTestScenarioStartingOldDeviceUnavailable = 32,
    ASIOSExpectedRouteChangeTestScenarioStartingCategory = 33,
    ASIOSExpectedRouteChangeTestScenarioStartingChannelMismatch = 34,
    ASIOSExpectedRouteChangeTestScenarioStartingCoalescedExactRoute = 35,
    ASIOSExpectedRouteChangeTestScenarioStartingOutputChanged = 36,
    ASIOSExpectedRouteChangeTestScenarioStartingInactive = 37,
    ASIOSExpectedRouteChangeTestScenarioStartingWrongGeneration = 38,
    ASIOSExpectedRouteChangeTestScenarioStartingWrongSystemGeneration = 39,
    ASIOSExpectedRouteChangeTestScenarioStartingTargetMismatch = 40,
    ASIOSExpectedRouteChangeTestScenarioStartingPreferredMismatch = 41,
    ASIOSExpectedRouteChangeTestScenarioStartingExplicitResumeRequired = 42,
    ASIOSExpectedRouteChangeTestScenarioPendingOutputChanged = 43,
    ASIOSExpectedRouteChangeTestScenarioConvergedStartSettlementCoalescedExactRoute = 44,
    ASIOSExpectedRouteChangeTestScenarioConvergedStartSettlementExpired = 45,
};

typedef NS_ENUM(NSInteger, ASIOSExpectedCategoryObservationTestScenario) {
    ASIOSExpectedCategoryObservationTestScenarioMicrophoneExact = 0,
    ASIOSExpectedCategoryObservationTestScenarioOutputOnlyExact = 1,
    ASIOSExpectedCategoryObservationTestScenarioUntracked = 2,
    ASIOSExpectedCategoryObservationTestScenarioWrongOptions = 3,
    ASIOSExpectedCategoryObservationTestScenarioWrongMode = 4,
    ASIOSExpectedCategoryObservationTestScenarioWrongSharingPolicy = 5,
    ASIOSExpectedCategoryObservationTestScenarioWrongConfigurationGeneration = 6,
    ASIOSExpectedCategoryObservationTestScenarioWrongSystemAudioGeneration = 7,
    ASIOSExpectedCategoryObservationTestScenarioSequenceNotAdvanced = 8,
    ASIOSExpectedCategoryObservationTestScenarioExpired = 9,
};

/// Drives the real queued recovery boundary without starting playout or touching audio hardware.
@interface ASIOSStereoPlayoutRecoveryTestHarness : NSObject

@property(nonatomic, readonly) ASIOSStereoPlayoutDiagnostics diagnostics;
@property(nonatomic, readonly) NSUInteger queuedOperationCount;
/// Number of invocations of the production audio-policy configuration boundary. The deterministic
/// harness records the exact inputs to that operation but does not create a hardware AudioUnit.
@property(nonatomic, readonly) NSUInteger configurationOperationCount;
@property(nonatomic, copy, readonly) NSArray<NSString *> *lastChannelPreferenceOperations;
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
- (ASIOSMicrophoneStageFailureReason)
    debugClassifyMicrophoneStageFailureForTestingWithWantsPlayout:
        (BOOL)wantsPlayout
                                                       interrupted:
        (BOOL)interrupted
                                            explicitResumeRequired:
        (BOOL)explicitResumeRequired
                                                  recoveryRequired:
        (BOOL)recoveryRequired
    NS_SWIFT_NAME(debugClassifyMicrophoneStageFailureForTesting(wantsPlayout:interrupted:explicitResumeRequired:recoveryRequired:));
- (BOOL)setMicrophoneAuthorizationForTesting:
    (ASIOSMicrophoneAuthorization *_Nullable)authorization
    NS_SWIFT_NAME(setMicrophoneAuthorizationForTesting(_:));
- (BOOL)debugPublishCurrentMicrophoneAuthorizationForTesting;
- (BOOL)debugBeginRealtimeAdmissionForTesting;
- (void)debugEndRealtimeAdmissionForTesting;
- (void)debugCloseAndFenceRealtimeGateForTesting;
- (void)waitForRealtimeGateClosureForTesting;
- (BOOL)debugTerminateForTesting;
- (BOOL)debugApplyActiveChannelPreferencesForTestingWithSessionActive:
    (BOOL)sessionActive
                                       maximumInputChannels:
    (NSInteger)maximumInputChannels
                                      maximumOutputChannels:
    (NSInteger)maximumOutputChannels
                                            microphoneEnabled:
    (BOOL)microphoneEnabled
    NS_SWIFT_NAME(debugApplyActiveChannelPreferencesForTesting(sessionActive:maximumInputChannels:maximumOutputChannels:microphoneEnabled:));
- (ASIOSExpectedRouteChangeDisposition)
    debugClassifyExpectedRouteChangeForTesting:
        (ASIOSExpectedRouteChangeTestScenario)scenario
    NS_SWIFT_NAME(debugClassifyExpectedRouteChangeForTesting(_:));
- (BOOL)debugExpectedCategoryObservationIsAbsorbedForTesting:
    (ASIOSExpectedCategoryObservationTestScenario)scenario
    NS_SWIFT_NAME(debugExpectedCategoryObservationIsAbsorbedForTesting(_:));
- (BOOL)debugDriveRetiredExpectedCategoryObservationForTestingWithExactPolicy:
    (BOOL)exactPolicy
    NS_SWIFT_NAME(debugDriveRetiredExpectedCategoryObservationForTesting(exactPolicy:));
- (BOOL)debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting;
- (BOOL)debugSupersededRouteObservationIsSuppressedForTestingWithOldDeviceUnavailable:
    (BOOL)oldDeviceUnavailable
    NS_SWIFT_NAME(debugSupersededRouteObservationIsSuppressedForTesting(oldDeviceUnavailable:));
- (BOOL)debugRetiredSystemGenerationRouteObservationIsSuppressedForTestingWithOldDeviceUnavailable:
    (BOOL)oldDeviceUnavailable
    NS_SWIFT_NAME(debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(oldDeviceUnavailable:));
- (BOOL)debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting;
- (BOOL)debugRecordedConsumedRouteClosureUsesFreshRouteForTesting;
- (BOOL)debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting;
- (BOOL)debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting;
- (BOOL)debugRouteEvidenceOwnsMicrophonePublicationClosureForTestingWithRecordedClosure:
    (BOOL)recordedClosure
                                                                         inFlightCount:
                                                                             (NSUInteger)inFlightCount
    NS_SWIFT_NAME(debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(recordedClosure:inFlightCount:));
- (BOOL)debugTrackedCategoryObservationOwnsRouteClosureForTesting;
- (BOOL)debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting;
- (BOOL)debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting;
- (BOOL)debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting;
- (BOOL)debugRouteLockedOwnershipSnapshotComparatorForTesting;
- (BOOL)debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting;
- (BOOL)debugClearRetiresInFlightExpectedRouteObservationForTesting;
- (BOOL)debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting;
- (NSString *)debugStructuredRouteTransactionFailureSnapshotForTesting;
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
- (void)debugAttemptFailureOverwriteForTesting;
- (void)debugAdvanceSystemAudioGenerationForTesting;
- (void)debugSetOutputRouteAvailableForTesting:(BOOL)available;
- (void)debugSetCaptureRouteBuiltInMicrophoneForTesting:(BOOL)isBuiltIn;
- (void)debugFailNextHostedCallActivationForTesting;
- (BOOL)runNextQueuedOperation;

@end

/// Deterministic exact-object tests for both NotificationCenter observer orders and bounded
/// fallback. It never registers an AVAudioSession observer or touches audio hardware.
@interface ASIOSRouteConfigurationChangeArbitrationTestHarness : NSObject

- (BOOL)debugWaiterFirstResolvesForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition
    NS_SWIFT_NAME(debugWaiterFirstResolvesForTesting(_:));
- (BOOL)debugNativeFirstResolvesForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition
    NS_SWIFT_NAME(debugNativeFirstResolvesForTesting(_:));
- (BOOL)debugNativeFirstResolverReplacementPreservesDispositionForTesting:
    (ASIOSRouteConfigurationChangeDisposition)disposition
    NS_SWIFT_NAME(debugNativeFirstResolverReplacementPreservesDispositionForTesting(_:));
- (BOOL)debugExactNotificationIdentityRejectsStaleResolutionForTesting;
- (BOOL)debugTimeoutCompletesExactlyOnceForTesting;
- (BOOL)debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting;
- (NSUInteger)debugArbitrationRecordCountForTesting;

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

/// Synchronously retires this peer-owned ADM on its serialized WebRTC device queue. YES proves
/// RemoteIO, authorization gates, AVAudioSession ownership, callbacks, and the delegate reached
/// their terminal state. NO means native teardown or session deactivation failed and replacement
/// audio ownership must remain barred.
- (BOOL)terminateForPeerRetirement
    NS_SWIFT_NAME(terminateForPeerRetirement());

#if DEBUG
- (void)debugFailNextPeerRetirementTerminationForTesting;
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
