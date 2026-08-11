#import <Foundation/Foundation.h>
#import <LiveKitWebRTC/RTCPeerConnectionFactory.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ASMacWebRTCAudioDeviceErrorDomain;

typedef NS_ERROR_ENUM(ASMacWebRTCAudioDeviceErrorDomain, ASMacWebRTCAudioDeviceError) {
    ASMacWebRTCAudioDeviceErrorFactoryClassMissing = 1,
    ASMacWebRTCAudioDeviceErrorFactorySelectorMissing = 2,
    ASMacWebRTCAudioDeviceErrorFactorySelectorABIMismatch = 3,
    ASMacWebRTCAudioDeviceErrorDelegateProtocolMissing = 4,
    ASMacWebRTCAudioDeviceErrorDelegateBridgeClassMissing = 5,
    ASMacWebRTCAudioDeviceErrorDelegateBridgeABIMismatch = 6,
    ASMacWebRTCAudioDeviceErrorFactoryCreationFailed = 7,
};

/// Opaque lock-free gate for one AudioQueue callback-context lifecycle.
///
/// Callback entry increments an in-flight count only while the gate is open.
/// Teardown closes the gate, waits for admitted callbacks, disposes the queue,
/// and only then releases the callback context retained for that queue.
typedef void *ASMacAudioQueueCallbackLifetimeRef;

FOUNDATION_EXPORT ASMacAudioQueueCallbackLifetimeRef _Nullable
ASMacAudioQueueCallbackLifetimeCreate(void);

FOUNDATION_EXPORT void ASMacAudioQueueCallbackLifetimeDestroy(
    ASMacAudioQueueCallbackLifetimeRef lifetime
);

FOUNDATION_EXPORT bool ASMacAudioQueueCallbackLifetimeTryEnter(
    ASMacAudioQueueCallbackLifetimeRef lifetime
);

FOUNDATION_EXPORT void ASMacAudioQueueCallbackLifetimeLeave(
    ASMacAudioQueueCallbackLifetimeRef lifetime
);

FOUNDATION_EXPORT void ASMacAudioQueueCallbackLifetimeClose(
    ASMacAudioQueueCallbackLifetimeRef lifetime
);

FOUNDATION_EXPORT void ASMacAudioQueueCallbackLifetimeWaitForCallbacks(
    ASMacAudioQueueCallbackLifetimeRef lifetime
);

/// Opaque lock-free authorization boundary for hidden-writer PCM.
///
/// New gates are closed. `Close` is a synchronous, nonblocking revocation
/// suitable for a Core Audio property-listener callback. The AudioQueue
/// callback must observe this gate both before pulling caller PCM and before
/// publishing its buffer to Core Audio.
typedef void *ASMacAudioQueueWriterAuthorizationGateRef;

FOUNDATION_EXPORT ASMacAudioQueueWriterAuthorizationGateRef _Nullable
ASMacAudioQueueWriterAuthorizationGateCreate(void);

FOUNDATION_EXPORT void ASMacAudioQueueWriterAuthorizationGateDestroy(
    ASMacAudioQueueWriterAuthorizationGateRef gate
);

/// Captures the current revocation generation for one prospective admission.
FOUNDATION_EXPORT uint64_t
ASMacAudioQueueWriterAuthorizationGatePrepareToOpen(
    ASMacAudioQueueWriterAuthorizationGateRef gate
);

/// Opens only if no close occurred since `expectedGeneration` was captured.
FOUNDATION_EXPORT bool ASMacAudioQueueWriterAuthorizationGateOpenIfUnchanged(
    ASMacAudioQueueWriterAuthorizationGateRef gate,
    uint64_t expectedGeneration
);

FOUNDATION_EXPORT void ASMacAudioQueueWriterAuthorizationGateClose(
    ASMacAudioQueueWriterAuthorizationGateRef gate
);

FOUNDATION_EXPORT bool ASMacAudioQueueWriterAuthorizationGateIsOpen(
    ASMacAudioQueueWriterAuthorizationGateRef gate
);

/// Opaque lock-free boundary for one AudioQueue runtime-failure lifecycle.
///
/// The realtime producer publishes only the first nonzero status. A non-realtime
/// consumer can take that status exactly once. Reset is valid only while no
/// callback from the previous lifecycle can still publish.
typedef void *ASMacAudioQueueRuntimeFailureLatchRef;

FOUNDATION_EXPORT ASMacAudioQueueRuntimeFailureLatchRef _Nullable
ASMacAudioQueueRuntimeFailureLatchCreate(void);

FOUNDATION_EXPORT void ASMacAudioQueueRuntimeFailureLatchDestroy(
    ASMacAudioQueueRuntimeFailureLatchRef latch
);

FOUNDATION_EXPORT void ASMacAudioQueueRuntimeFailureLatchReset(
    ASMacAudioQueueRuntimeFailureLatchRef latch
);

FOUNDATION_EXPORT void ASMacAudioQueueRuntimeFailureLatchPublish(
    ASMacAudioQueueRuntimeFailureLatchRef latch,
    int32_t status
);

FOUNDATION_EXPORT bool ASMacAudioQueueRuntimeFailureLatchTake(
    ASMacAudioQueueRuntimeFailureLatchRef latch,
    int32_t *status
);

/// Opaque lock-free post-start progress for one AudioQueue lifecycle.
///
/// Priming is deliberately excluded. The owner resets before startup, marks the
/// queue running only after AudioQueueStart succeeds, and publishes only from
/// admitted realtime callbacks.
typedef void *ASMacAudioQueueProgressRef;

typedef struct ASMacAudioQueueProgressSnapshot {
    bool queueRunning;
    uint64_t postStartCallbackCount;
    uint64_t requestedFrameCount;
    uint64_t successfulPullCount;
    uint64_t successfulFrameCount;
    uint64_t silenceFallbackCount;
    uint64_t silenceFrameCount;
    uint64_t enqueueFailureCount;
    int32_t lastEnqueueStatus;
} ASMacAudioQueueProgressSnapshot;

FOUNDATION_EXPORT ASMacAudioQueueProgressRef _Nullable
ASMacAudioQueueProgressCreate(void);

FOUNDATION_EXPORT void ASMacAudioQueueProgressDestroy(
    ASMacAudioQueueProgressRef progress
);

FOUNDATION_EXPORT void ASMacAudioQueueProgressReset(
    ASMacAudioQueueProgressRef progress
);

FOUNDATION_EXPORT void ASMacAudioQueueProgressSetQueueRunning(
    ASMacAudioQueueProgressRef progress,
    bool queueRunning
);

FOUNDATION_EXPORT void ASMacAudioQueueProgressPublish(
    ASMacAudioQueueProgressRef progress,
    uint64_t requestedFrameCount,
    bool pullSucceeded,
    int32_t enqueueStatus
);

FOUNDATION_EXPORT ASMacAudioQueueProgressSnapshot
ASMacAudioQueueProgressRead(
    ASMacAudioQueueProgressRef progress
);

/// Opaque lock-free publication boundary for the final AudioQueue PCM buffer.
///
/// The realtime producer publishes fixed-size scalar aggregates for completed
/// windows. It never publishes or retains PCM. Reset is valid only after the
/// outgoing callback lifetime has been closed and drained.
typedef void *ASMacAudioQueuePCMContentRef;

typedef struct ASMacAudioQueuePCMContentRawWindow {
    /// Exact half-open source-frame interval represented by this window.
    uint64_t sourceStartFrame;
    uint64_t sourceEndFrame;
    /// Canonical FNV-1a 64 over every interleaved Int16 sample in the window. Each
    /// sample is reinterpreted as UInt16 and hashed low byte then high byte.
    uint64_t windowFingerprint;
    uint64_t frameCount;
    int64_t leftSampleSum;
    int64_t rightSampleSum;
    uint64_t leftSquareSum;
    uint64_t rightSquareSum;
    int64_t leftRightProductSum;
    uint64_t sumSquareSum;
    uint64_t differenceSquareSum;
    uint64_t leftPeak;
    uint64_t rightPeak;
    uint64_t leftZeroCount;
    uint64_t rightZeroCount;
    uint64_t leftClippingCount;
    uint64_t rightClippingCount;
    uint64_t oneSidedFrameCount;
} ASMacAudioQueuePCMContentRawWindow;

typedef struct ASMacAudioQueuePCMContentSnapshot {
    bool hasCompletedWindow;
    /// Monotonic publication lifecycle. Reset advances this value and never reuses
    /// a prior window sequence, so a concurrent reader cannot accept an ABA payload.
    uint64_t lifecycleGeneration;
    uint64_t windowSequence;
    uint64_t completedFrameCount;
    ASMacAudioQueuePCMContentRawWindow window;
} ASMacAudioQueuePCMContentSnapshot;

FOUNDATION_EXPORT ASMacAudioQueuePCMContentRef _Nullable
ASMacAudioQueuePCMContentCreate(void);

FOUNDATION_EXPORT void ASMacAudioQueuePCMContentDestroy(
    ASMacAudioQueuePCMContentRef content
);

FOUNDATION_EXPORT void ASMacAudioQueuePCMContentReset(
    ASMacAudioQueuePCMContentRef content
);

FOUNDATION_EXPORT void ASMacAudioQueuePCMContentPublish(
    ASMacAudioQueuePCMContentRef content,
    ASMacAudioQueuePCMContentRawWindow window
);

FOUNDATION_EXPORT ASMacAudioQueuePCMContentSnapshot
ASMacAudioQueuePCMContentRead(
    ASMacAudioQueuePCMContentRef content
);

#if DEBUG
/// Test-only deterministic interlock for proving a read spanning reset/publication cannot accept
/// an ABA or hybrid payload. The hold applies to the next reader that observes a publication.
FOUNDATION_EXPORT void ASMacAudioQueuePCMContentHoldReadForTesting(
    ASMacAudioQueuePCMContentRef content
);
FOUNDATION_EXPORT void ASMacAudioQueuePCMContentReleaseReadForTesting(
    ASMacAudioQueuePCMContentRef content
);
FOUNDATION_EXPORT bool ASMacAudioQueuePCMContentReadIsHeldForTesting(
    ASMacAudioQueuePCMContentRef content
);
#endif

/// A lock-consistent cumulative snapshot of the source-clock custom device.
///
/// Every successful input callback is captured Mac PCM. There is no recording timer, ring,
/// jitter buffer, clock PLL, partial-quantum padding, or synthetic silence in this device.
typedef struct ASMacStereoAudioDeviceDiagnostics {
    bool initialized;
    bool recordingInitialized;
    bool recording;
    bool playoutInitialized;
    bool playing;
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
    /// Must remain zero: production always supplies the pinned native bridge a render block and
    /// never the stereo-truncating prefilled AudioBufferList path.
    uint64_t prefilledInputDataDeliveryCount;
    uint64_t timestampResetCount;
    uint64_t recordingGeneration;
    uint64_t approvedRecordingGeneration;
    uint64_t admissionBlockedFrameCount;
    uint64_t inputInterruptionCount;
    uint64_t deliveryThreadChangeCount;
    uint32_t lastDeliveryFrameCount;
    double lastDeliverySampleTime;
    uint64_t lastDeliveryHostTime;
    uint64_t playoutCallbackCount;
    uint64_t playoutFrameCount;
    uint64_t playoutFailureCount;
    uint64_t playoutPullsInFlight;
    uint64_t playoutFenceWaitCount;
} ASMacStereoAudioDeviceDiagnostics;

/// Privacy-safe decoded-content evidence from the caller-owned stereo playout boundary.
///
/// Content-derived fields describe only the latest completed exact 48,000-frame window. An
/// arbitrary render callback may be divided between adjacent scalar windows while its PCM remains
/// solely in caller-owned storage for the duration of the callback. Exact render/frame/byte
/// evidence is cumulative for the device lifetime. The realtime path retains scalar sums and a
/// non-reversible FNV-1a fingerprint only; RMS, dBFS, fractions, and centered Pearson correlation
/// are derived by this off-callback snapshot accessor. No PCM is retained.
typedef struct ASMacDecodedPlayoutTelemetrySnapshot {
    uint64_t playoutGeneration;

    /// Exact cumulative caller/native contract evidence.
    uint64_t renderCallCount;
    uint64_t requestedFrameCount;
    uint64_t requestedByteCount;
    uint64_t returnedByteCount;
    uint64_t nativeSuccessRenderCallCount;
    uint64_t nativeFailureRenderCallCount;
    uint64_t exactBufferContractCount;
    uint64_t bufferContractMismatchCount;
    uint64_t analyzedRenderCallCount;
    uint64_t analyzedFrameCount;
    uint64_t analyzedByteCount;
    uint64_t droppedTelemetryRenderCallCount;
    uint64_t pendingWindowFrameCount;
    uint64_t latestRenderCall;
    int32_t latestRenderStatus;
    uint32_t latestRequestedFrameCount;
    uint32_t latestRequestedByteCount;
    uint32_t latestReturnedByteCount;
    bool latestBufferContractWasExact;

    /// Latest completed content window. False until the current playout generation completes one.
    bool hasCompletedWindow;
    uint64_t completedWindowSequence;
    uint64_t completedWindowGeneration;
    uint64_t completedWindowFirstRenderCall;
    uint64_t completedWindowLastRenderCall;
    uint64_t completedWindowRenderCallCount;
    uint64_t completedWindowFrameCount;
    uint64_t completedWindowByteCount;
    /// Exact half-open playout source-frame interval represented by the window.
    uint64_t completedWindowSourceStartFrame;
    uint64_t completedWindowSourceEndFrame;
    /// Canonical FNV-1a 64 over interleaved Int16 sample bytes, low byte then high byte.
    uint64_t completedWindowFingerprint;
    double completedWindowDurationSeconds;

    double leftRMS;
    double rightRMS;
    double leftRMSDecibelsFS;
    double rightRMSDecibelsFS;
    double leftPeak;
    double rightPeak;
    double leftPeakDecibelsFS;
    double rightPeakDecibelsFS;
    double leftDC;
    double rightDC;
    uint64_t leftZeroSampleCount;
    uint64_t rightZeroSampleCount;
    double leftZeroFraction;
    double rightZeroFraction;
    uint64_t leftClippedSampleCount;
    uint64_t rightClippedSampleCount;
    double leftClippingFraction;
    double rightClippingFraction;
    bool leftRightCorrelationIsValid;
    double leftRightCorrelation;
    double sumPower;
    double differencePower;
    uint64_t oneSidedFrameCount;
    double oneSidedFraction;

    bool windowIsAllZero;
    bool windowIsLeftOnly;
    bool windowIsRightOnly;
    uint64_t allZeroBlockCount;
    uint64_t leftOnlyBlockCount;
    uint64_t rightOnlyBlockCount;
    uint64_t frozenBlockCount;
    uint64_t longestFrozenBlockRun;
} ASMacDecodedPlayoutTelemetrySnapshot;

/// Source-clock WebRTC device used by the Mac host.
///
/// ScreenCaptureKit PCM is converted on one serial application queue and passed straight through
/// this object to WebRTC. The native adapter's FineAudioBuffer performs any 10 ms accumulation or
/// splitting internally. Decoded remote playout can also be pulled into caller-owned memory.
@interface ASMacStereoAudioDevice : NSObject

/// Synchronously delivers one complete source callback. `samples` contains exactly
/// `frameCount * 2` signed 16-bit values in L,R order at 48 kHz. Arbitrary positive hardware
/// callback sizes are accepted; the caller retains ownership for the duration of this call.
- (BOOL)deliverInterleavedStereoInt16:(const int16_t *)samples
                           frameCount:(NSUInteger)frameCount;

/// Admits source PCM only for the exact current native StartRecording generation. A later native
/// restart increments the generation and therefore fails closed until the peer re-verifies its
/// raw APM state and approves again.
- (BOOL)approveCurrentRecordingGeneration;

/// Admits source PCM only if `recordingGeneration` is the exact current
/// nonzero StartRecording generation.
- (BOOL)approveRecordingGeneration:(uint64_t)recordingGeneration
    NS_SWIFT_NAME(approveRecordingGeneration(_:));

- (void)revokeRecordingAdmission;

/// Pulls decoded stereo PCM directly into caller-owned output-device memory.
/// The method performs no allocation, logging, sleeping, network work, or
/// contended locking. Failure leaves the destination as silence.
- (BOOL)renderPlayoutInterleavedStereoInt16:(int16_t *)samples
                                  frameCount:(NSUInteger)frameCount
    NS_SWIFT_NAME(renderPlayoutInterleavedStereoInt16(_:frameCount:));

/// Pulls one arbitrary-size playout block without opening hardware. Production Mac hosts are
/// send-only; this explicit pull exists for embedders and deterministic headless codec tests.
- (BOOL)pullHeadlessPlayoutFrames:(NSUInteger)frameCount;

#if DEBUG
/// Holds a caller-owned playout pull after it has entered the production
/// lifetime gate, allowing tests to prove StopPlayout waits for that pull.
- (void)holdPlayoutPullsForTesting;
- (void)releasePlayoutPullsForTesting;
@property(nonatomic, readonly) BOOL playoutPullIsHeldForTesting;
- (BOOL)stopPlayoutAndFenceForTesting;

/// Pauses one diagnostics reader immediately after it observes a completed-window publication.
/// Test-only: allows a reset/new publication to be interleaved deterministically.
- (void)holdDecodedTelemetryReadsForTesting;
- (void)releaseDecodedTelemetryReadsForTesting;
@property(nonatomic, readonly) BOOL decodedTelemetryReadIsHeldForTesting;
#endif

@property(nonatomic, readonly) ASMacStereoAudioDeviceDiagnostics diagnostics;

/// Reads one consistent completed content window plus monotonic exact contract counters.
/// Call only from a non-realtime diagnostics context.
@property(nonatomic, readonly) ASMacDecodedPlayoutTelemetrySnapshot decodedPlayoutTelemetry;

@end

/// Verifies the exact Objective-C entry points used by the compatibility shim. This is a runtime
/// guard in addition to Package.swift's exact LiveKitWebRTC 144.7559.11 dependency pin.
FOUNDATION_EXPORT BOOL ASMacWebRTCAudioDevicePreflight(NSError *_Nullable *_Nullable error);

/// Constructs a peer-connection factory backed by `audioDevice`. On this custom-device path,
/// `LKRTCPeerConnectionFactory.audioDeviceModule` is expected to be nil; callers feed PCM through
/// `ASMacStereoAudioDevice` instead of the public AudioEngine observer API.
FOUNDATION_EXPORT LKRTCPeerConnectionFactory *_Nullable
ASCreateMacStereoPeerConnectionFactory(
    id<LKRTCVideoEncoderFactory> _Nullable encoderFactory,
    id<LKRTCVideoDecoderFactory> _Nullable decoderFactory,
    ASMacStereoAudioDevice *audioDevice,
    NSError *_Nullable *_Nullable error
);

NS_ASSUME_NONNULL_END
