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
    uint32_t lastPlayoutFrameCount;
    int32_t lastPlayoutStatus;
} ASIOSStereoPlayoutDiagnostics;

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
/// WebRTC's ADM thread.
- (void)requestPlayoutRecovery;

@end

NS_ASSUME_NONNULL_END
