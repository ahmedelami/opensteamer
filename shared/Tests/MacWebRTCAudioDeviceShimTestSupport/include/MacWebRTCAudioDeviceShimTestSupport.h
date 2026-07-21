#import <Foundation/Foundation.h>
#import "MacWebRTCAudioDeviceShim.h"

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Scripted delegate behaviors that prove the production bridge fails closed when the native
/// render contract is skipped, duplicated, or invoked with invalid storage.
typedef NS_ENUM(NSInteger, ASMacStereoAudioDeviceHarnessDeliveryBehavior) {
    ASMacStereoAudioDeviceHarnessDeliveryBehaviorInvokeRenderOnce = 0,
    ASMacStereoAudioDeviceHarnessDeliveryBehaviorReturnSuccessWithoutRender = 1,
    ASMacStereoAudioDeviceHarnessDeliveryBehaviorInvokeRenderTwice = 2,
    ASMacStereoAudioDeviceHarnessDeliveryBehaviorReturnSuccessAfterInvalidRender = 3,
};

/// Exact callback, sample-pattern, and timestamp evidence collected by the test-only delegate.
typedef struct ASMacStereoAudioDeviceHarnessDiagnostics {
    uint64_t callbackCount;
    uint64_t frameCount;
    uint64_t invalidBufferListCount;
    uint64_t samplePatternMismatchCount;
    uint64_t sampleTimeDiscontinuityCount;
    uint64_t hostTimeDiscontinuityCount;
    uint64_t inputInterruptionNotificationCount;
    uint64_t directInputDataCallbackCount;
    uint64_t renderBlockCallbackCount;
    uint64_t renderedSampleElementCount;
    uint64_t playoutCallbackCount;
    uint64_t playoutSampleTimeDiscontinuityCount;
    uint64_t playoutHostTimeDiscontinuityCount;
    uint64_t outputInterruptionNotificationCount;
    uint32_t lastFrameCount;
    double lastSampleTime;
    uint64_t lastHostTime;
    uint32_t lastPlayoutFrameCount;
    double lastPlayoutSampleTime;
    uint64_t lastPlayoutHostTime;
} ASMacStereoAudioDeviceHarnessDiagnostics;

/// Exact RTCAudioDevice-delegate harness used only by the macOS shim test target. It validates the
/// production AudioBufferList, timestamps, and deterministic [marker, -marker] stereo sequence
/// without involving an audio device, timer, or application PCM queue.
@interface ASMacStereoAudioDeviceTestHarness : NSObject

- (instancetype)initWithDevice:(ASMacStereoAudioDevice *)device
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startRecording;
- (BOOL)repeatStartRecording;
- (BOOL)restartRecording;
- (BOOL)restartRecordingWithoutApproval;
- (BOOL)approveCurrentRecordingGeneration;
- (BOOL)stopRecording;
- (BOOL)startPlayout;
- (BOOL)repeatStartPlayout;
- (BOOL)stopPlayout;
- (BOOL)deliverStereoSequenceOnNewThreadStartingAtFrame:(uint64_t)startFrame
                                             frameCount:(NSUInteger)frameCount
    NS_SWIFT_NAME(deliverStereoSequenceOnNewThread(startingAtFrame:frameCount:));

@property(nonatomic) ASMacStereoAudioDeviceHarnessDeliveryBehavior deliveryBehavior;

@property(nonatomic, readonly) ASMacStereoAudioDeviceHarnessDiagnostics diagnostics;

@end

/// Starts only the Objective-C device side while retaining the real native delegate installed by
/// the peer factory. Native ADM remains inactive, reproducing its documented `noErr` return with
/// zero render-block invocations.
FOUNDATION_EXPORT BOOL
ASStartMacStereoDeviceRecordingWithoutStartingNativeADM(ASMacStereoAudioDevice *device);

NS_ASSUME_NONNULL_END
