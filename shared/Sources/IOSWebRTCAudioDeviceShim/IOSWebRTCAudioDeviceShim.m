#import "IOSWebRTCAudioDeviceShim.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdatomic.h>

static const double ASSampleRate = 48000.0;
static const NSTimeInterval ASIOBufferDuration = 0.010;
static const UInt32 ASOutputChannelCount = 2;

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

typedef struct ASRealtimeDiagnostics {
    atomic_uint_fast64_t callbackCount;
    atomic_uint_fast64_t frameCount;
    atomic_uint_fast64_t failureCount;
    atomic_uint_fast64_t recordingRequestCount;
    atomic_uint_fast64_t recoveryRequestCount;
    atomic_uint_fast64_t recoveryAuthorizationRejectionCount;
    atomic_uint_fast64_t recoveryRebuildCount;
    atomic_uint_fast32_t lastFrameCount;
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
    atomic_uint_fast32_t audioUnitSubType;
    atomic_int_fast32_t failureCode;
    atomic_int_fast32_t lastLifecycleStatus;
} ASLifecycleDiagnostics;

@interface ASIOSStereoPlayoutRecoveryAuthorization () {
    os_unfair_lock _lock;
    atomic_bool _valid;
}
@end

@interface ASIOSStereoPlayoutAudioDevice () {
@public
    // The C render trampoline reads the copied block ivar directly and writes only lock-free
    // counters. It performs no Objective-C property access or message send.
    LKRTCAudioDeviceGetPlayoutDataBlock _playoutBlock;
    ASRealtimeDiagnostics _realtime;
@private
    ASLifecycleDiagnostics _lifecycle;
    AudioComponentInstance _audioUnit;
    AudioStreamBasicDescription _streamFormat;
    BOOL _initialized;
    BOOL _playoutInitialized;
    BOOL _playing;
    BOOL _wantsPlayout;
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
}
@property(atomic, strong, nullable) id<LKRTCAudioDeviceDelegate> delegate;
@property(atomic, copy, readwrite, nullable) NSString *lastLifecycleFailureMessage;
- (BOOL)configureSessionAndCreateRemoteIO;
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
- (void)rebuildAfterExplicitRecovery;
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

static inline void ASInitializeRealtimeDiagnostics(
    ASRealtimeDiagnostics *diagnostics
) {
    atomic_init(&diagnostics->callbackCount, 0);
    atomic_init(&diagnostics->frameCount, 0);
    atomic_init(&diagnostics->failureCount, 0);
    atomic_init(&diagnostics->recordingRequestCount, 0);
    atomic_init(&diagnostics->recoveryRequestCount, 0);
    atomic_init(&diagnostics->recoveryAuthorizationRejectionCount, 0);
    atomic_init(&diagnostics->recoveryRebuildCount, 0);
    atomic_init(&diagnostics->lastFrameCount, 0);
    atomic_init(&diagnostics->lastStatus, noErr);
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
    snapshot.lastFrameCount = atomic_load_explicit(
        &diagnostics->lastFrameCount,
        memory_order_relaxed
    );
    snapshot.lastStatus = atomic_load_explicit(
        &diagnostics->lastStatus,
        memory_order_relaxed
    );
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

- (BOOL)runNextQueuedOperation {
    dispatch_block_t operation = [self.delegate takeNextOperation];
    if (operation == nil) {
        return NO;
    }
    operation();
    return YES;
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
        ASPublishPlayoutCallback(
            &device->_realtime,
            frameCount,
            kAudio_ParamError
            #if DEBUG
            , NULL, NULL
            #endif
        );
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
    if (status != noErr) {
        ASZeroAudioBufferList(outputData);
        if (actionFlags != NULL) {
            *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        }
    }
    ASPublishPlayoutCallback(
        &device->_realtime,
        frameCount,
        status
        #if DEBUG
        , NULL, NULL
        #endif
    );
    return status;
}

@implementation ASIOSStereoPlayoutAudioDevice

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    ASInitializeRealtimeDiagnostics(&_realtime);
    atomic_init(&_lifecycle.initialized, false);
    atomic_init(&_lifecycle.playoutInitialized, false);
    atomic_init(&_lifecycle.playing, false);
    atomic_init(&_lifecycle.sessionActive, false);
    atomic_init(&_lifecycle.remoteIOCreated, false);
    atomic_init(&_lifecycle.inputBusEnabled, false);
    atomic_init(&_lifecycle.outputBusEnabled, false);
    atomic_init(&_lifecycle.recoveryRequired, false);
    atomic_init(&_lifecycle.explicitResumeRequired, false);
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
        NSTimeInterval duration = AVAudioSession.sharedInstance.IOBufferDuration;
        if (duration > 0) {
            return duration;
        }
    }
    return ASIOBufferDuration;
}
- (NSInteger)outputNumberOfChannels { return ASOutputChannelCount; }
- (NSTimeInterval)outputLatency {
    return AVAudioSession.sharedInstance.outputLatency;
}
- (BOOL)isInitialized { return _initialized; }
- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)isRecordingInitialized { return _initialized; }
- (BOOL)isRecording { return NO; }

- (BOOL)initializeWithDelegate:(id<LKRTCAudioDeviceDelegate>)delegate {
    if (_initialized || delegate == nil) {
        return NO;
    }
    self.delegate = delegate;
    _playoutBlock = [delegate.getPlayoutData copy];
    if (_playoutBlock == nil) {
        self.delegate = nil;
        return NO;
    }
    _wantsPlayout = NO;
    _interrupted = NO;
    _recoveryRequired = NO;
    _explicitResumeRequired = NO;
    _isRebuilding = NO;
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    [self clearLifecycleFailure];
    _initialized = YES;
    atomic_store_explicit(&_lifecycle.initialized, true, memory_order_relaxed);
    [self subscribeToSystemAudioNotifications];
    return YES;
}

- (BOOL)terminateDevice {
    if (!_initialized && _audioUnit == NULL && _sessionOwnershipToken == 0) {
        return YES;
    }
    _wantsPlayout = NO;
    [self unsubscribeFromSystemAudioNotifications];
    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
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
    atomic_store_explicit(&_lifecycle.playoutInitialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.initialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.recoveryRequired, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.explicitResumeRequired, false, memory_order_relaxed);
    // AudioOutputUnitStop/AudioComponentInstanceDispose above form the lifetime boundary: no
    // render callback can still be using the copied block when it is cleared here.
    _playoutBlock = nil;
    self.delegate = nil;
    return teardownStatus == noErr && deactivated;
}

- (BOOL)initializePlayout {
    if (!_initialized || _interrupted || _recoveryRequired || _explicitResumeRequired) {
        return NO;
    }
    if (_playoutInitialized && _audioUnit != NULL) {
        return YES;
    }
    return [self configureSessionAndCreateRemoteIO];
}

- (BOOL)startPlayout {
    _wantsPlayout = YES;
    if (_interrupted || _recoveryRequired || _explicitResumeRequired) {
        if (atomic_load_explicit(&_lifecycle.failureCode, memory_order_relaxed)
            == ASIOSStereoPlayoutFailureNone) {
            [self publishFailureCode:ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                             status:noErr
                            message:@"Playout is fail-closed until application-authorized recovery."];
        }
        return NO;
    }
    if (![self initializePlayout] || _audioUnit == NULL) {
        return NO;
    }
    if (_playing) {
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
    // Native ADM may ask about the unused direction while constructing its bridge. Reporting the
    // no-resource direction initialized avoids opening any input hardware.
    return _initialized;
}

- (BOOL)startRecording {
    atomic_fetch_add_explicit(&_realtime.recordingRequestCount, 1, memory_order_relaxed);
    return NO;
}

- (BOOL)stopRecording { return YES; }

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
        return;
    }
    __weak ASIOSStereoPlayoutAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        ASIOSStereoPlayoutAudioDevice *self = weakSelf;
        if (self == nil || !self->_initialized) {
            return;
        }
        BOOL authorized = [authorization performIfValid:^{
            // App lifecycle signals may request recovery while healthy playout is already running.
            // Treat those signals as idempotent: rebuilding RemoteIO would introduce an audible gap
            // and briefly relinquish an otherwise valid media-playback audio session.
            if (!self->_recoveryRequired
                && !self->_explicitResumeRequired
                && self->_playing
                && self->_playoutInitialized
                && self->_audioUnit != NULL
                && [self ownsCurrentSessionActivation]) {
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
            [self rebuildAfterExplicitRecovery];
        }];
        if (!authorized) {
            atomic_fetch_add_explicit(
                &self->_realtime.recoveryAuthorizationRejectionCount,
                1,
                memory_order_relaxed
            );
        }
    }];
}

- (ASIOSStereoPlayoutDiagnostics)diagnostics {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    BOOL ownsSessionActivation = [self ownsCurrentSessionActivation];
    BOOL sessionActive = atomic_load_explicit(
        &_lifecycle.sessionActive,
        memory_order_relaxed
    ) && ownsSessionActivation;
    ASIOSStereoPlayoutDiagnostics diagnostics = {0};
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
    diagnostics.categoryIsMediaPlayback = [session.category
        isEqualToString:AVAudioSessionCategoryPlayback];
    diagnostics.modeIsDefault = [session.mode isEqualToString:AVAudioSessionModeDefault];
    diagnostics.sampleRate = session.sampleRate;
    diagnostics.outputIOBufferDuration = session.IOBufferDuration;
    diagnostics.outputChannelCount = session.outputNumberOfChannels;
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
    diagnostics.lastPlayoutFrameCount = atomic_load_explicit(
        &_realtime.lastFrameCount,
        memory_order_relaxed
    );
    diagnostics.lastPlayoutStatus = atomic_load_explicit(
        &_realtime.lastStatus,
        memory_order_relaxed
    );
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
    return diagnostics;
}

- (BOOL)configureSessionAndCreateRemoteIO {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // This is a general Mac-audio monitor, not movie playback. MoviePlayback deliberately
    // engages route-dependent output enhancement; Default keeps the media path free of that
    // requested coloration. No category options means no app-requested mixing or call route.
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:0
                        error:&error]) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSessionConfiguration
                               status:(int32_t)error.code
                              message:[NSString stringWithFormat:
                                  @"Media playback category configuration failed: %@",
                                  error.localizedDescription ?: @"unknown error"]];
        return NO;
    }
    if (![session setPreferredSampleRate:ASSampleRate error:&error]
        || ![session setPreferredIOBufferDuration:ASIOBufferDuration error:&error]
        || ![session setPreferredOutputNumberOfChannels:ASOutputChannelCount error:&error]) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSessionPreference
                               status:(int32_t)error.code
                              message:[NSString stringWithFormat:
                                  @"Media playback hardware preference failed: %@",
                                  error.localizedDescription ?: @"unknown error"]];
        return NO;
    }
    if (![self activateOwnedSession:session error:&error]) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureSessionActivation
                               status:(int32_t)error.code
                              message:[NSString stringWithFormat:
                                  @"Media playback audio-session activation failed: %@",
                                  error.localizedDescription ?: @"unknown error"]];
        return NO;
    }

    // Fail closed rather than silently falling back to a call/HFP/mono route.
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]
        || ![session.mode isEqualToString:AVAudioSessionModeDefault]
        || fabs(session.sampleRate - ASSampleRate) >= 0.5
        || session.IOBufferDuration <= 0
        || session.outputNumberOfChannels < ASOutputChannelCount) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureMediaRouteInvariant
                               status:kAudio_ParamError
                              message:[NSString stringWithFormat:
                                  @"The active route is not 48 kHz stereo media playback "
                                   @"(category=%@, mode=%@, rate=%.1f, duration=%.6f, channels=%ld).",
                                  session.category,
                                  session.mode,
                                  session.sampleRate,
                                  session.IOBufferDuration,
                                  (long)session.outputNumberOfChannels]];
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

    UInt32 disabled = 0;
    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        1,
        &disabled,
        sizeof(disabled)
    );
    if (status != noErr) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureMicrophoneBusDisable
                               status:(int32_t)status
                              message:[NSString stringWithFormat:
                                  @"Failed to disable RemoteIO microphone bus (%d).",
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
    if (_inputBusEnabled || !_outputBusEnabled) {
        [self failAndRollbackWithCode:ASIOSStereoPlayoutFailureBusValidation
                               status:kAudio_ParamError
                              message:@"RemoteIO did not preserve the output-only bus invariant."];
        return NO;
    }

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
    os_unfair_lock_lock(&ASSessionOwnershipLock);
    BOOL owns = _sessionOwnershipToken != 0
        && ASCurrentSessionOwnershipToken == _sessionOwnershipToken;
    os_unfair_lock_unlock(&ASSessionOwnershipLock);
    return owns;
}

- (void)failAndRollbackWithCode:(ASIOSStereoPlayoutFailureCode)code
                         status:(int32_t)status
                        message:(NSString *)message {
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
    _playing = NO;
    _playoutInitialized = NO;
    _inputBusEnabled = NO;
    _outputBusEnabled = NO;
    _audioUnitSubType = 0;
    atomic_store_explicit(&_lifecycle.playing, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.playoutInitialized, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.remoteIOCreated, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.inputBusEnabled, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.outputBusEnabled, false, memory_order_relaxed);
    atomic_store_explicit(&_lifecycle.audioUnitSubType, 0, memory_order_relaxed);
    return firstFailure;
}

- (void)rebuildAfterExplicitRecovery {
    if (_isRebuilding) {
        return;
    }
    ASCrossExplicitRecoveryBoundary(&_realtime);
    _isRebuilding = YES;
    BOOL shouldResume = _wantsPlayout && !_interrupted;
    if (_audioUnit != NULL || _playing) {
        [self.delegate notifyAudioOutputInterrupted];
    }
    OSStatus teardownStatus = [self stopAndDisposeAudioUnit];
    NSError *deactivationError = nil;
    BOOL deactivated = [self deactivateOwnedSessionWithError:&deactivationError];
    if (teardownStatus != noErr) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureAudioUnitStop
                         status:(int32_t)teardownStatus
                        message:[NSString stringWithFormat:
                            @"RemoteIO teardown failed before explicit recovery (%d).",
                            (int)teardownStatus]];
        _isRebuilding = NO;
        return;
    }
    if (!deactivated) {
        [self publishFailureCode:ASIOSStereoPlayoutFailureSessionDeactivation
                         status:(int32_t)deactivationError.code
                        message:[NSString stringWithFormat:
                            @"Audio-session deactivation failed before explicit recovery: %@",
                            deactivationError.localizedDescription ?: @"unknown error"]];
        _isRebuilding = NO;
        return;
    }
    if (!shouldResume) {
        [self clearLifecycleFailure];
        _isRebuilding = NO;
        return;
    }
    if ([self configureSessionAndCreateRemoteIO]) {
        [self.delegate notifyAudioOutputParametersChange];
        [self startPlayout];
    }
    _isRebuilding = NO;
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
            _recoveryRequired = YES;
            atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
            [self failClosedForSystemEventWithCode:
                ASIOSStereoPlayoutFailureRouteChangeRecoveryRequired
                                           message:@"Audio interruption ended; application-authorized recovery is required."];
            return;

        case ASSystemAudioEventRouteChanged: {
            AVAudioSession *session = AVAudioSession.sharedInstance;
            if (routeReason == AVAudioSessionRouteChangeReasonCategoryChange) {
                BOOL expected = [session.category isEqualToString:AVAudioSessionCategoryPlayback]
                    && [session.mode isEqualToString:AVAudioSessionModeDefault];
                if (expected) {
                    return;
                }
                _recoveryRequired = YES;
                atomic_store_explicit(&_lifecycle.recoveryRequired, true, memory_order_relaxed);
                [self failClosedForSystemEventWithCode:
                    ASIOSStereoPlayoutFailureUnexpectedCategoryChange
                                               message:[NSString stringWithFormat:
                                                   @"Unexpected audio category/mode change (%@/%@); playout is fail-closed.",
                                                   session.category,
                                                   session.mode]];
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
