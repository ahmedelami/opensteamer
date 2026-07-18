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
} ASMacStereoAudioDeviceDiagnostics;

/// Source-clock input-only WebRTC device used by the Mac host.
///
/// ScreenCaptureKit PCM is converted on one serial application queue and passed straight through
/// this object to WebRTC. The native adapter's FineAudioBuffer performs any 10 ms accumulation or
/// splitting internally. This object never opens or reads a physical microphone.
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
- (void)revokeRecordingAdmission;

/// Pulls one arbitrary-size playout block without opening hardware. Production Mac hosts are
/// send-only; this explicit pull exists for embedders and deterministic headless codec tests.
- (BOOL)pullHeadlessPlayoutFrames:(NSUInteger)frameCount;

@property(nonatomic, readonly) ASMacStereoAudioDeviceDiagnostics diagnostics;

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
