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
    uint64_t unexpectedRecordingRequestCount;
    uint64_t recoveryRequestCount;
    uint64_t recoveryAuthorizationRejectionCount;
    uint64_t recoveryRebuildCount;
    uint32_t lastPlayoutFrameCount;
    int32_t lastPlayoutStatus;
} ASIOSStereoPlayoutDiagnostics;

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

#if DEBUG
typedef struct ASIOSStereoPlayoutPublicationSnapshot {
    uint64_t callbackCount;
    uint64_t frameCount;
    uint64_t failureCount;
    uint32_t lastFrameCount;
    int32_t lastStatus;
} ASIOSStereoPlayoutPublicationSnapshot;

/// Invokes the production callback-publication primitive without touching audio hardware.
@interface ASIOSStereoPlayoutPublicationTestHarness : NSObject

@property(nonatomic, readonly) ASIOSStereoPlayoutPublicationSnapshot prePublicationSnapshot;
@property(nonatomic, readonly) ASIOSStereoPlayoutPublicationSnapshot snapshot;

- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                status:(int32_t)status;
- (void)markRecoveryBoundary;

@end

/// Drives the real queued recovery boundary without starting playout or touching audio hardware.
@interface ASIOSStereoPlayoutRecoveryTestHarness : NSObject

@property(nonatomic, readonly) ASIOSStereoPlayoutDiagnostics diagnostics;
@property(nonatomic, readonly) NSUInteger queuedOperationCount;

- (void)publishCallbackWithFrameCount:(uint32_t)frameCount
                                status:(int32_t)status;
- (void)queueRecoveryWithAuthorization:
    (ASIOSStereoPlayoutRecoveryAuthorization *)authorization
    NS_SWIFT_NAME(queueRecovery(authorization:));
- (BOOL)runNextQueuedOperation;

@end
#endif

/// Output-only WebRTC audio device for iPhone/iPad viewers.
///
/// The device owns one `kAudioUnitSubType_RemoteIO` instance. Its input bus is always disabled,
/// so it cannot open the microphone. RemoteIO's realtime render callback passes its buffer list
/// directly to WebRTC's cached `getPlayoutData` block exactly once. There is no intermediate
/// player node, PCM copy, second audio-device output, or application ring buffer.
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

@end

NS_ASSUME_NONNULL_END
