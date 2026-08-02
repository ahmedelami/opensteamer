import AudioToolbox
import CaptureCore
import Darwin
import Dispatch
import Foundation
import MacWebRTCAudioDeviceShim
import WebRTCTransport

struct BlackHoleMicrophoneOutputProgressSnapshot:
    Equatable,
    Sendable
{
    let queueRunning: Bool
    let postStartCallbackCount: UInt64
    let requestedFrameCount: UInt64
    let successfulPullCount: UInt64
    let successfulFrameCount: UInt64
    let silenceFallbackCount: UInt64
    let silenceFrameCount: UInt64
    let enqueueFailureCount: UInt64
    let lastEnqueueStatus: OSStatus

    static let zero = Self(
        queueRunning: false,
        postStartCallbackCount: 0,
        requestedFrameCount: 0,
        successfulPullCount: 0,
        successfulFrameCount: 0,
        silenceFallbackCount: 0,
        silenceFrameCount: 0,
        enqueueFailureCount: 0,
        lastEnqueueStatus: noErr
    )
}

private final class BlackHoleMicrophoneOutputProgressStorage:
    @unchecked Sendable
{
    let reference: ASMacAudioQueueProgressRef

    init?() {
        guard let reference = ASMacAudioQueueProgressCreate() else {
            return nil
        }
        self.reference = reference
    }

    deinit {
        ASMacAudioQueueProgressDestroy(reference)
    }

    func reset() {
        ASMacAudioQueueProgressReset(reference)
    }

    func setQueueRunning(_ queueRunning: Bool) {
        ASMacAudioQueueProgressSetQueueRunning(
            reference,
            queueRunning
        )
    }

    func publish(
        requestedFrameCount: UInt64,
        pullSucceeded: Bool,
        enqueueStatus: OSStatus
    ) {
        ASMacAudioQueueProgressPublish(
            reference,
            requestedFrameCount,
            pullSucceeded,
            enqueueStatus
        )
    }

    var snapshot: BlackHoleMicrophoneOutputProgressSnapshot {
        let native = ASMacAudioQueueProgressRead(reference)
        return BlackHoleMicrophoneOutputProgressSnapshot(
            queueRunning: native.queueRunning,
            postStartCallbackCount:
                native.postStartCallbackCount,
            requestedFrameCount: native.requestedFrameCount,
            successfulPullCount: native.successfulPullCount,
            successfulFrameCount: native.successfulFrameCount,
            silenceFallbackCount: native.silenceFallbackCount,
            silenceFrameCount: native.silenceFrameCount,
            enqueueFailureCount: native.enqueueFailureCount,
            lastEnqueueStatus: native.lastEnqueueStatus
        )
    }
}

struct BlackHoleMicrophoneOutputQueueDisposalRedriveResult:
    Equatable,
    Sendable
{
    let retainedCount: Int
    let lastFailureStatus: OSStatus?

    var permitsReplacement: Bool {
        retainedCount == 0
    }
}

/// Compatibility facade for older call sites. `AudioQueueDispose` is terminal in the
/// macOS 26 SDK regardless of its returned status, so queue disposal is no longer
/// retried or retained after the call returns.
final class BlackHoleMicrophoneOutputQueueDisposalRetainer:
    @unchecked Sendable
{
    static let shared =
        BlackHoleMicrophoneOutputQueueDisposalRetainer()

    @discardableResult
    func redriveRetained(
        maximumAttemptCount _: Int
    ) -> BlackHoleMicrophoneOutputQueueDisposalRedriveResult {
        BlackHoleMicrophoneOutputQueueDisposalRedriveResult(
            retainedCount: 0,
            lastFailureStatus: nil
        )
    }

    var retainedDisposalCount: Int { 0 }

    #if DEBUG
    var debugFirstCallbackContextPointerForTesting:
        UnsafeMutableRawPointer? {
        nil
    }
    #endif
}

/// Output-device-clock sink for the decoded `iphone-microphone` track.

///
/// Core Audio owns the fixed buffers. The realtime callback performs one
/// caller-owned WebRTC pull and re-enqueues the same buffer; unavailable data
/// stays zero-filled. Callback failures cross only a lock-free status latch.
final class BlackHoleMicrophoneOutput: @unchecked Sendable {
    typealias RuntimeFailureHandler = @Sendable (
        BlackHoleMicrophoneOutput,
        BlackHoleMicrophoneOutputError
    ) -> Void

    private static let createQueueOperation =
        "create BlackHole output queue"
    private static let createCallbackLifetimeOperation =
        "create BlackHole output callback lifetime"
    private static let selectDeviceOperation =
        "select BlackHole 2ch by UID"
    private static let allocateBufferOperation =
        "allocate BlackHole output buffer"
    private static let primeBufferOperation =
        "prime BlackHole output buffer"
    private static let startQueueOperation =
        "start BlackHole output queue"
    private static let disposeQueueOperation =
        "dispose BlackHole output queue"
    private static let runtimeEnqueueOperation =
        "re-enqueue BlackHole output buffer"
    private static let runtimeFailureReportingQueueKey =
        DispatchSpecificKey<UInt8>()
    private static let runtimeFailureReportingQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "opensteamer.BlackHoleMicrophoneOutput.RuntimeFailure",
            qos: .utility
        )
        queue.setSpecific(
            key: runtimeFailureReportingQueueKey,
            value: 1
        )
        return queue
    }()
    private static let runtimeFailurePollInterval =
        DispatchTimeInterval.milliseconds(10)
    private static let runtimeFailureTimerLeeway =
        DispatchTimeInterval.milliseconds(2)
    private static let defaultProgressStallGraceNanoseconds: UInt64 =
        2_000_000_000

    private let source: WebRTCMacDecodedAudioSource?
    private let deviceUID: String
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let progressStorage: BlackHoleMicrophoneOutputProgressStorage
    private let runtimeFailureHandler: RuntimeFailureHandler
    private let automaticallyReportsRuntimeFailures: Bool
    private var audioQueue: AudioQueueRef?
    private var callbackContext: BlackHoleMicrophoneOutputCallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var lastDisposeStatus: OSStatus?
    private var runtimeFailureTimer: (any DispatchSourceTimer)?
    private var runtimeFailureGeneration: UInt64 = 0
    private var activeRuntimeFailureGeneration: UInt64?
    private var runtimeFailureMonitoringStartTime: UInt64?
    private var lastObservedPostStartCallbackCount: UInt64 = 0
    private var lastPostStartCallbackAdvanceTime: UInt64?
    private var lastObservedSuccessfulFrameCount: UInt64 = 0
    private var lastSuccessfulFrameAdvanceTime: UInt64?
    private var didReportRuntimeFailure = false
    private let runtimeFailureNow:
        @Sendable () -> UInt64
    private let progressStallGraceNanoseconds: UInt64
    private let framesPerBuffer: UInt32 = 480
    private let channelCount: UInt32 = 2

    #if DEBUG
    private let testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private let renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    private let deinitForTesting: (@Sendable () -> Void)?
    private let callbackContextDeinitForTesting:
        (@Sendable () -> Void)?
    private let runtimeEnqueueFailurePublicationInterlockForTesting:
        BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?
    #endif

    init?(
        source: WebRTCMacDecodedAudioSource,
        deviceUID: String,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard !deviceUID.isEmpty else {
            return nil
        }
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }
        guard let progressStorage =
                BlackHoleMicrophoneOutputProgressStorage() else {
            return nil
        }

        self.source = source
        self.deviceUID = deviceUID
        self.runtimeFailureLatch = runtimeFailureLatch
        self.progressStorage = progressStorage
        self.runtimeFailureHandler = runtimeFailureHandler
        automaticallyReportsRuntimeFailures = true
        runtimeFailureNow = { DispatchTime.now().uptimeNanoseconds }
        progressStallGraceNanoseconds = Self.defaultProgressStallGraceNanoseconds
        #if DEBUG
        testingAudioQueueOperations = nil
        renderForTesting = nil
        deinitForTesting = nil
        callbackContextDeinitForTesting = nil
        runtimeEnqueueFailurePublicationInterlockForTesting =
            nil
        #endif
    }

    #if DEBUG
    init?(
        testingAudioQueueOperations:
            any BlackHoleMicrophoneOutputAudioQueueOperations,
        deviceUID: String = "BlackHole2ch_UID",
        automaticallyReportsRuntimeFailures: Bool = false,
        runtimeFailureNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        progressStallGraceNanoseconds: UInt64 = 2_000_000_000,
        runtimeEnqueueFailurePublicationInterlockForTesting:
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock? = nil,
        renderForTesting: @escaping (
            UnsafeMutablePointer<Int16>,
            Int
        ) -> Bool = { _, _ in false },
        queueDisposalRetainer:
            BlackHoleMicrophoneOutputQueueDisposalRetainer =
                .shared,
        maximumQueueDisposalAttemptCountPerEpisode:
            Int = 3,
        callbackContextDeinitForTesting: (@Sendable () -> Void)? = nil,
        deinitForTesting: (@Sendable () -> Void)? = nil,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard !deviceUID.isEmpty else {
            return nil
        }
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }
        guard let progressStorage =
                BlackHoleMicrophoneOutputProgressStorage() else {
            return nil
        }

        source = nil
        self.deviceUID = deviceUID
        self.runtimeFailureLatch = runtimeFailureLatch
        self.progressStorage = progressStorage
        self.runtimeFailureHandler = runtimeFailureHandler
        self.automaticallyReportsRuntimeFailures =
            automaticallyReportsRuntimeFailures
        self.runtimeFailureNow = runtimeFailureNow
        self.progressStallGraceNanoseconds = progressStallGraceNanoseconds
        _ = queueDisposalRetainer
        _ = maximumQueueDisposalAttemptCountPerEpisode
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
        self.deinitForTesting = deinitForTesting
        self.callbackContextDeinitForTesting =
            callbackContextDeinitForTesting
        self.runtimeEnqueueFailurePublicationInterlockForTesting =
            runtimeEnqueueFailurePublicationInterlockForTesting
    }
    #endif

    deinit {
        stop()
        #if DEBUG
        deinitForTesting?()
        #endif
    }


    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot {
        progressStorage.snapshot
    }

    func start() throws {
        guard audioQueue == nil else { return }

        runtimeFailureLatch.reset()
        progressStorage.reset()
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        guard let callbackLifetime =
                ASMacAudioQueueCallbackLifetimeCreate() else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createCallbackLifetimeOperation,
                kAudio_MemFullError
            )
        }

        let callbackContext: BlackHoleMicrophoneOutputCallbackContext
        #if DEBUG
        callbackContext = BlackHoleMicrophoneOutputCallbackContext(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount,
            progressStorage: progressStorage,
            testingAudioQueueOperations: testingAudioQueueOperations,
            renderForTesting: renderForTesting,
            runtimeEnqueueFailurePublicationInterlockForTesting:
                runtimeEnqueueFailurePublicationInterlockForTesting,
            deinitForTesting:
                callbackContextDeinitForTesting
        )
        #else
        callbackContext = BlackHoleMicrophoneOutputCallbackContext(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount,
            progressStorage: progressStorage
        )
        #endif
        let callbackContextPointer = Unmanaged
            .passRetained(callbackContext)
            .toOpaque()
        let creation = createOutputQueue(
            format: &format,
            context: callbackContextPointer
        )
        guard creation.status == noErr else {
            cleanupCreatedQueue(
                creation.queue,
                callbackContext: callbackContext,
                callbackContextPointer: callbackContextPointer,
                didAttemptStart: false
            )
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createQueueOperation,
                creation.status
            )
        }
        guard let queue = creation.queue else {
            cleanupCreatedQueue(
                nil,
                callbackContext: callbackContext,
                callbackContextPointer: callbackContextPointer,
                didAttemptStart: false
            )
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createQueueOperation,
                kAudio_ParamError
            )
        }

        var createdBuffers: [AudioQueueBufferRef] = []
        createdBuffers.reserveCapacity(3)
        var didAttemptStart = false
        var startupCommitted = false
        defer {
            if !startupCommitted {
                cleanupCreatedQueue(
                    queue,
                    callbackContext: callbackContext,
                    callbackContextPointer: callbackContextPointer,
                    didAttemptStart: didAttemptStart
                )
            }
        }

        let deviceStatus = setCurrentDevice(deviceUID, on: queue)
        guard deviceStatus == noErr else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.selectDeviceOperation,
                deviceStatus
            )
        }

        let byteCount = framesPerBuffer
            * channelCount
            * UInt32(MemoryLayout<Int16>.size)
        for _ in 0..<3 {
            let allocation = allocateBuffer(
                on: queue,
                byteCount: byteCount
            )
            guard allocation.status == noErr else {
                if let buffer = allocation.buffer {
                    createdBuffers.append(buffer)
                }
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.allocateBufferOperation,
                    allocation.status
                )
            }
            guard let buffer = allocation.buffer else {
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.allocateBufferOperation,
                    kAudio_ParamError
                )
            }

            createdBuffers.append(buffer)
            let primingResult = callbackContext.fillAndEnqueue(
                queue: queue,
                buffer: buffer
            )
            guard primingResult.enqueueStatus == noErr else {
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.primeBufferOperation,
                    primingResult.enqueueStatus
                )
            }
        }

        didAttemptStart = true
        let startStatus = startQueue(queue)
        guard startStatus == noErr else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.startQueueOperation,
                startStatus
            )
        }

        audioQueue = queue
        self.callbackContext = callbackContext
        self.callbackContextPointer = callbackContextPointer
        buffers = createdBuffers
        progressStorage.setQueueRunning(true)
        startupCommitted = true
        startRuntimeFailureMonitoring(
            scheduleTimer: automaticallyReportsRuntimeFailures
        )
    }

    func stop() {
        stopRuntimeFailureMonitoring()
        guard let queue = audioQueue,
              let callbackContext,
              let callbackContextPointer else {
            return
        }

        audioQueue = nil
        self.callbackContext = nil
        self.callbackContextPointer = nil
        buffers.removeAll(keepingCapacity: false)

        closeStopDisposeAndRelease(
            queue: queue,
            callbackContext: callbackContext,
            callbackContextPointer: callbackContextPointer,
            didAttemptStart: true
        )
    }

    private func cleanupCreatedQueue(
        _ queue: AudioQueueRef?,
        callbackContext: BlackHoleMicrophoneOutputCallbackContext,
        callbackContextPointer: UnsafeMutableRawPointer,
        didAttemptStart: Bool
    ) {
        guard let queue else {
            callbackContext.closeCallbacks()
            callbackContext.waitForCallbacks()
            Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
                .fromOpaque(callbackContextPointer)
                .release()
            return
        }

        closeStopDisposeAndRelease(
            queue: queue,
            callbackContext: callbackContext,
            callbackContextPointer: callbackContextPointer,
            didAttemptStart: didAttemptStart
        )
    }

    private func closeStopDisposeAndRelease(
        queue: AudioQueueRef,
        callbackContext: BlackHoleMicrophoneOutputCallbackContext,
        callbackContextPointer: UnsafeMutableRawPointer,
        didAttemptStart: Bool
    ) {
        callbackContext.closeCallbacks()
        if didAttemptStart {
            _ = stopQueue(queue, immediate: true)
        }
        callbackContext.waitForCallbacks()
        let status = disposeQueue(queue, immediate: true)
        lastDisposeStatus = status
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
    }

    private func startRuntimeFailureMonitoring(

        scheduleTimer: Bool
    ) {
        withRuntimeFailureReportingQueue {
            guard activeRuntimeFailureGeneration == nil else {
                return
            }

            runtimeFailureGeneration = Self.nextNonzero(
                runtimeFailureGeneration
            )
            let generation = runtimeFailureGeneration
            activeRuntimeFailureGeneration = generation
            runtimeFailureMonitoringStartTime =
                runtimeFailureNow()
            lastObservedPostStartCallbackCount = 0
            lastPostStartCallbackAdvanceTime = nil
            lastObservedSuccessfulFrameCount = 0
            lastSuccessfulFrameAdvanceTime = nil
            didReportRuntimeFailure = false

            guard scheduleTimer else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: Self.runtimeFailureReportingQueue
            )
            timer.schedule(
                deadline: .now()
                    + Self.runtimeFailurePollInterval,
                repeating: Self.runtimeFailurePollInterval,
                leeway: Self.runtimeFailureTimerLeeway
            )
            timer.setEventHandler { [weak self] in
                self?.pollRuntimeFailureMonitoring(
                    generation: generation
                )
            }
            runtimeFailureTimer = timer
            timer.activate()
        }
    }

    private func stopRuntimeFailureMonitoring() {
        withRuntimeFailureReportingQueue {
            progressStorage.setQueueRunning(false)
            activeRuntimeFailureGeneration = nil
            runtimeFailureGeneration = Self.nextNonzero(
                runtimeFailureGeneration
            )
            runtimeFailureMonitoringStartTime = nil
            lastObservedPostStartCallbackCount = 0
            lastPostStartCallbackAdvanceTime = nil
            lastObservedSuccessfulFrameCount = 0
            lastSuccessfulFrameAdvanceTime = nil
            didReportRuntimeFailure = false

            let timer = runtimeFailureTimer
            runtimeFailureTimer = nil
            timer?.setEventHandler {}
            timer?.cancel()
        }
    }

    private func pollRuntimeFailureMonitoring(
        generation: UInt64
    ) {
        withRuntimeFailureReportingQueue {
            guard activeRuntimeFailureGeneration == generation,
                  !didReportRuntimeFailure else {
                return
            }

            let progress = progressStorage.snapshot
            guard progress.queueRunning else { return }

            let now = runtimeFailureNow()
            var shouldReportProgressStall = false
            let successfulFrameCount =
                progress.successfulFrameCount
            if successfulFrameCount > 0 {
                if successfulFrameCount
                        > lastObservedSuccessfulFrameCount {
                    lastObservedSuccessfulFrameCount =
                        successfulFrameCount
                    lastSuccessfulFrameAdvanceTime = now
                } else if let lastSuccessfulFrameAdvanceTime,
                          now >= lastSuccessfulFrameAdvanceTime,
                          now - lastSuccessfulFrameAdvanceTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                }
            } else {
                let callbackCount =
                    progress.postStartCallbackCount
                if callbackCount
                        > lastObservedPostStartCallbackCount {
                    lastObservedPostStartCallbackCount =
                        callbackCount
                    lastPostStartCallbackAdvanceTime = now
                } else if callbackCount == 0,
                          let runtimeFailureMonitoringStartTime,
                          now >= runtimeFailureMonitoringStartTime,
                          now - runtimeFailureMonitoringStartTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                } else if callbackCount > 0,
                          let lastPostStartCallbackAdvanceTime,
                          now >= lastPostStartCallbackAdvanceTime,
                          now - lastPostStartCallbackAdvanceTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                }
            }

            if let status = runtimeFailureLatch.take() {
                didReportRuntimeFailure = true
                runtimeFailureHandler(
                    self,
                    .operation(
                        Self.runtimeEnqueueOperation,
                        status
                    )
                )
                return
            }

            guard shouldReportProgressStall else {
                return
            }

            didReportRuntimeFailure = true
            runtimeFailureHandler(
                self,
                .progressStalled
            )
        }
    }

    private func withRuntimeFailureReportingQueue<T>(
        _ body: () -> T
    ) -> T {
        if DispatchQueue.getSpecific(
            key: Self.runtimeFailureReportingQueueKey
        ) != nil {
            return body()
        }
        return Self.runtimeFailureReportingQueue.sync(
            execute: body
        )
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private func createOutputQueue(
        format: inout AudioStreamBasicDescription,
        context: UnsafeMutableRawPointer
    ) -> (status: OSStatus, queue: AudioQueueRef?) {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.createOutputQueue()
        }
        #endif

        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &format,
            blackHoleMicrophoneOutputCallback,
            context,
            nil,
            nil,
            0,
            &queue
        )
        return (status, queue)
    }

    private func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations
                .setCurrentDevice(uid, on: queue)
        }
        #endif

        var value = uid as CFString
        return withUnsafePointer(to: &value) {
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                $0,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
    }

    private func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (status: OSStatus, buffer: AudioQueueBufferRef?) {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.allocateBuffer(
                on: queue,
                byteCount: byteCount
            )
        }
        #endif

        var buffer: AudioQueueBufferRef?
        let status = AudioQueueAllocateBuffer(
            queue,
            byteCount,
            &buffer
        )
        return (status, buffer)
    }

    @inline(__always)
    private func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.enqueueBuffer(
                buffer,
                on: queue
            )
        }
        #endif
        return AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func startQueue(_ queue: AudioQueueRef) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.startQueue(queue)
        }
        #endif
        return AudioQueueStart(queue, nil)
    }

    private func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.stopQueue(
                queue,
                immediate: immediate
            )
        }
        #endif
        return AudioQueueStop(queue, immediate)
    }

    private func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.freeBuffer(
                buffer,
                from: queue
            )
        }
        #endif
        return AudioQueueFreeBuffer(queue, buffer)
    }

    private func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.disposeQueue(
                queue,
                immediate: immediate
            )
        }
        #endif
        return AudioQueueDispose(queue, immediate)
    }

    #if DEBUG
    func debugInvokeRealtimeCallbackForTesting(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        guard let callbackContextPointer else { return }
        blackHoleMicrophoneOutputCallback(
            callbackContextPointer,
            queue,
            buffer
        )
    }

    func debugRealtimeCallbackContextForTesting()
        -> UnsafeMutableRawPointer? {
        callbackContextPointer
    }

    var debugHasPendingQueueDisposalForTesting: Bool {
        false
    }

    var debugLastDisposeStatusForTesting: OSStatus? {
        lastDisposeStatus
    }

    static func debugInvokeRealtimeCallbackWithContextForTesting(
        context: UnsafeMutableRawPointer,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        blackHoleMicrophoneOutputCallback(
            context,
            queue,
            buffer
        )
    }

    func debugReportLatchedRuntimeFailureForTesting() {
        guard let generation =
                debugRuntimeFailureMonitoringGenerationForTesting() else {
            return
        }
        debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
    }

    func debugRuntimeFailureMonitoringGenerationForTesting()
        -> UInt64? {
        withRuntimeFailureReportingQueue {
            activeRuntimeFailureGeneration
        }
    }

    func debugPollRuntimeFailureMonitoringForTesting(
        generation: UInt64
    ) {
        pollRuntimeFailureMonitoring(generation: generation)
    }
    #endif
}

private struct BlackHoleMicrophoneOutputCallbackResult {
    let requestedFrameCount: UInt64
    let pullSucceeded: Bool
    let enqueueStatus: OSStatus
}

#if DEBUG
/// DEBUG-only AudioQueue replacement used by deterministic tests.
///
/// All references to this protocol and its dynamic dispatch are compiled out
/// of Release, leaving direct Core Audio calls on the production callback path.
protocol BlackHoleMicrophoneOutputAudioQueueOperations:
    AnyObject,
    Sendable
{
    func createOutputQueue() -> (
        status: OSStatus,
        queue: AudioQueueRef?
    )

    func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus

    func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (
        status: OSStatus,
        buffer: AudioQueueBufferRef?
    )

    func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus

    func startQueue(_ queue: AudioQueueRef) -> OSStatus

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus

    func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus
}
#endif

#if DEBUG
final class BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock:
    @unchecked Sendable
{
    private enum State {
        case disarmed
        case armed
        case paused
        case released
    }

    private let lock = NSLock()
    private let publicationReached = DispatchSemaphore(value: 0)
    private let callbackRelease = DispatchSemaphore(value: 0)
    private var state = State.disarmed

    func armNextFailureCallback() {
        lock.lock()
        defer { lock.unlock() }
        guard case .disarmed = state else {
            preconditionFailure(
                "Runtime enqueue failure interlock is already armed."
            )
        }
        state = .armed
    }

    fileprivate func pauseCallbackAfterPublication() {
        lock.lock()
        guard case .armed = state else {
            lock.unlock()
            return
        }
        state = .paused
        lock.unlock()

        publicationReached.signal()
        callbackRelease.wait()

        lock.lock()
        state = .disarmed
        lock.unlock()
    }

    func waitUntilCallbackPaused(
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        return publicationReached.wait(timeout: timeout)
    }

    func releaseCallback() {
        lock.lock()
        switch state {
        case .armed:
            state = .disarmed
            lock.unlock()
        case .paused:
            state = .released
            lock.unlock()
            callbackRelease.signal()
        case .disarmed, .released:
            lock.unlock()
        }
    }
}
#endif

private final class BlackHoleMicrophoneOutputCallbackContext:
    @unchecked Sendable
{
    private let callbackLifetime: UnsafeMutableRawPointer
    private let source: WebRTCMacDecodedAudioSource?
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let channelCount: UInt32
    private let progressStorage: BlackHoleMicrophoneOutputProgressStorage

    #if DEBUG
    private let testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private let renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    private let runtimeEnqueueFailurePublicationInterlockForTesting:
        BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?
    private let deinitForTesting:
        (@Sendable () -> Void)?
    #endif

    #if DEBUG
    init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32,
        progressStorage: BlackHoleMicrophoneOutputProgressStorage,
        testingAudioQueueOperations:
            (any BlackHoleMicrophoneOutputAudioQueueOperations)?,
        renderForTesting:
            ((UnsafeMutablePointer<Int16>, Int) -> Bool)?,
        runtimeEnqueueFailurePublicationInterlockForTesting:
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?,
        deinitForTesting:
            (@Sendable () -> Void)?
    ) {
        self.callbackLifetime = callbackLifetime
        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.channelCount = channelCount
        self.progressStorage = progressStorage
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
        self.runtimeEnqueueFailurePublicationInterlockForTesting =
            runtimeEnqueueFailurePublicationInterlockForTesting
        self.deinitForTesting = deinitForTesting
    }
    #else
    init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32,
        progressStorage: BlackHoleMicrophoneOutputProgressStorage
    ) {
        self.callbackLifetime = callbackLifetime
        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.channelCount = channelCount
        self.progressStorage = progressStorage
    }
    #endif

    deinit {
        ASMacAudioQueueCallbackLifetimeDestroy(callbackLifetime)
        #if DEBUG
        deinitForTesting?()
        #endif
    }

    @inline(__always)
    fileprivate func tryEnterCallback() -> Bool {
        ASMacAudioQueueCallbackLifetimeTryEnter(callbackLifetime)
    }

    @inline(__always)
    fileprivate func leaveCallback() {
        ASMacAudioQueueCallbackLifetimeLeave(callbackLifetime)
    }

    fileprivate func closeCallbacks() {
        ASMacAudioQueueCallbackLifetimeClose(callbackLifetime)
    }

    fileprivate func waitForCallbacks() {
        ASMacAudioQueueCallbackLifetimeWaitForCallbacks(
            callbackLifetime
        )
    }

    #if DEBUG
    @inline(__always)
    fileprivate func pauseRuntimeEnqueueFailurePublicationForTesting() {
        runtimeEnqueueFailurePublicationInterlockForTesting?
            .pauseCallbackAfterPublication()
    }
    #endif

    @inline(__always)
    fileprivate func fillAndEnqueue(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) -> BlackHoleMicrophoneOutputCallbackResult {
        let frameBytes = Int(channelCount) * MemoryLayout<Int16>.size
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let frameCount = capacity / frameBytes
        guard frameCount > 0 else {
            buffer.pointee.mAudioDataByteSize = 0
            return BlackHoleMicrophoneOutputCallbackResult(
                requestedFrameCount: 0,
                pullSucceeded: false,
                enqueueStatus: enqueueBuffer(
                    buffer,
                    on: queue
                )
            )
        }

        let rawData = buffer.pointee.mAudioData
        memset(rawData, 0, capacity)
        let samples = rawData.assumingMemoryBound(to: Int16.self)
        let pullSucceeded: Bool
        #if DEBUG
        if let renderForTesting {
            pullSucceeded = renderForTesting(samples, frameCount)
        } else if let source {
            pullSucceeded = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        } else {
            pullSucceeded = false
        }
        #else
        if let source {
            pullSucceeded = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        } else {
            pullSucceeded = false
        }
        #endif

        if !pullSucceeded {
            // A failed native renderer may have partially dirtied caller-owned
            // memory. Re-zero the full capacity before publishing silence.
            memset(rawData, 0, capacity)
        }

        buffer.pointee.mAudioDataByteSize =
            UInt32(frameCount * frameBytes)
        return BlackHoleMicrophoneOutputCallbackResult(
            requestedFrameCount: UInt64(frameCount),
            pullSucceeded: pullSucceeded,
            enqueueStatus: enqueueBuffer(buffer, on: queue)
        )
    }

    @inline(__always)
    fileprivate func publishProgress(
        _ result: BlackHoleMicrophoneOutputCallbackResult
    ) {
        progressStorage.publish(
            requestedFrameCount: result.requestedFrameCount,
            pullSucceeded: result.pullSucceeded,
            enqueueStatus: result.enqueueStatus
        )
    }

    @inline(__always)
    fileprivate func publishRuntimeEnqueueFailure(_ status: OSStatus) {
        runtimeFailureLatch.publish(status)
    }

    @inline(__always)
    private func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.enqueueBuffer(
                buffer,
                on: queue
            )
        }
        #endif
        return AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

private func blackHoleMicrophoneOutputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef
) {
    guard let userData else { return }
    let callbackContext =
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    guard callbackContext.tryEnterCallback() else { return }
    defer { callbackContext.leaveCallback() }

    let result = callbackContext.fillAndEnqueue(
        queue: queue,
        buffer: buffer
    )
    if result.enqueueStatus != noErr {
        // Publish the first-status latch before the multi-field progress
        // snapshot. A watchdog poll interleaved between these publications
        // must therefore select the enqueue failure.
        callbackContext.publishRuntimeEnqueueFailure(
            result.enqueueStatus
        )
        #if DEBUG
        callbackContext.pauseRuntimeEnqueueFailurePublicationForTesting()
        #endif
    }
    callbackContext.publishProgress(result)
}

enum BlackHoleMicrophoneOutputError:
    LocalizedError,
    Equatable,
    Sendable
{
    case operation(String, OSStatus)
    case progressStalled

    var errorDescription: String? {
        switch self {
        case .operation(let operation, let status):
            return "\(operation) failed with Core Audio status \(status)."
        case .progressStalled:
            return "BlackHole audio callback or decoded-frame progress " +
                "stalled while iPhone microphone forwarding was active."
        }
    }
}
