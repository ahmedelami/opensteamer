// Compatibility declarations copied from the public RTCAudioDevice.h in the exact-pinned
// LiveKitWebRTC 144.7559.11 iOS slice. The matching macOS binary contains objc_audio_device.mm
// and the injectable factory selector but accidentally omits this header from its umbrella.
// Keep these declarations private to this Clang target and re-audit them before any WebRTC bump.

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if !TARGET_OS_OSX
#error "RTCAudioDeviceCompat.h is only for the exact-pinned LiveKitWebRTC macOS slice."
#endif

#if __has_include(<LiveKitWebRTC/RTCAudioDevice.h>)
#import <LiveKitWebRTC/RTCAudioDevice.h>
#else

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^LKRTCAudioDeviceGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *outputData
);

typedef OSStatus (^LKRTCAudioDeviceRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *inputData,
    void *_Nullable renderContext
);

typedef OSStatus (^LKRTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList *_Nullable inputData,
    void *_Nullable renderContext,
    LKRTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock
);

@protocol LKRTCAudioDeviceDelegate <NSObject>
@property(readonly, nonnull) LKRTCAudioDeviceDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) LKRTCAudioDeviceGetPlayoutDataBlock getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol LKRTCAudioDevice <NSObject>
@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<LKRTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

NS_ASSUME_NONNULL_END

#endif
