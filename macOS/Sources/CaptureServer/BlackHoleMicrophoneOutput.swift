import AudioToolbox
import CaptureCore
import Darwin
import Dispatch
import Foundation
import MacWebRTCAudioDeviceShim
import WebRTCTransport

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
    private static let runtimeEnqueueOperation =
        "re-enqueue BlackHole output buffer"
    private static let runtimeFailureReportingQueue = DispatchQueue(
        label: "opensteamer.BlackHoleMicrophoneOutput.RuntimeFailure",
        qos: .utility
    )

    private let source: WebRTCMacDecodedAudioSource?
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let runtimeFailureHandler: RuntimeFailureHandler
    private let automaticallyReportsRuntimeFailures: Bool
    private var audioQueue: AudioQueueRef?
    private var callbackContext: BlackHoleMicrophoneOutputCallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var runtimeFailureTimer: (any DispatchSourceTimer)?
    private let framesPerBuffer: UInt32 = 480
    private let channelCount: UInt32 = 2

    #if DEBUG
    private let testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private let renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    private let deinitForTesting: (@Sendable () -> Void)?
    #endif

    init?(
        source: WebRTCMacDecodedAudioSource,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }

        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.runtimeFailureHandler = runtimeFailureHandler
        automaticallyReportsRuntimeFailures = true
        #if DEBUG
        testingAudioQueueOperations = nil
        renderForTesting = nil
        deinitForTesting = nil
        #endif
    }

    #if DEBUG
    init?(
        testingAudioQueueOperations:
            any BlackHoleMicrophoneOutputAudioQueueOperations,
        automaticallyReportsRuntimeFailures: Bool = false,
        renderForTesting: @escaping (
            UnsafeMutablePointer<Int16>,
            Int
        ) -> Bool = { _, _ in false },
        deinitForTesting: (@Sendable () -> Void)? = nil,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }

        source = nil
        self.runtimeFailureLatch = runtimeFailureLatch
        self.runtimeFailureHandler = runtimeFailureHandler
        self.automaticallyReportsRuntimeFailures =
            automaticallyReportsRuntimeFailures
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
        self.deinitForTesting = deinitForTesting
    }
    #endif

    deinit {
        stop()
        #if DEBUG
        deinitForTesting?()
        #endif
    }

    func start() throws {
        guard audioQueue == nil else { return }

        runtimeFailureLatch.reset()
        let deviceUID = try resolveBlackHole2ChannelDeviceUID()
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
            testingAudioQueueOperations: testingAudioQueueOperations,
            renderForTesting: renderForTesting
        )
        #else
        callbackContext = BlackHoleMicrophoneOutputCallbackContext(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount
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
            let enqueueStatus = callbackContext.fillAndEnqueue(
                queue: queue,
                buffer: buffer
            )
            guard enqueueStatus == noErr else {
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.primeBufferOperation,
                    enqueueStatus
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
        startupCommitted = true
        if automaticallyReportsRuntimeFailures {
            startRuntimeFailureMonitoring()
        }
    }

    func stop() {
        stopRuntimeFailureMonitoring()
        guard let queue = audioQueue,
              let callbackContext,
              let callbackContextPointer else { return }

        audioQueue = nil
        self.callbackContext = nil
        self.callbackContextPointer = nil
        buffers.removeAll(keepingCapacity: false)

        callbackContext.closeCallbacks()
        _ = stopQueue(queue, immediate: true)
        callbackContext.waitForCallbacks()

        let disposeStatus = disposeQueue(queue, immediate: true)
        guard disposeStatus == noErr else {
            // Core Audio may still invoke the supplied userData after a failed
            // dispose. Keep the queue's retained, closed context intentionally;
            // later callbacks fail the gate without touching Swift state.
            return
        }
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
    }

    private func cleanupCreatedQueue(
        _ queue: AudioQueueRef?,
        callbackContext: BlackHoleMicrophoneOutputCallbackContext,
        callbackContextPointer: UnsafeMutableRawPointer,
        didAttemptStart: Bool
    ) {
        callbackContext.closeCallbacks()
        if didAttemptStart, let queue {
            _ = stopQueue(queue, immediate: true)
        }
        callbackContext.waitForCallbacks()

        guard let queue else {
            Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
                .fromOpaque(callbackContextPointer)
                .release()
            return
        }

        // AudioQueueDispose is the sole owner of allocated queue-buffer teardown.
        let disposeStatus = disposeQueue(queue, immediate: true)
        guard disposeStatus == noErr else {
            // Preserve the closed context if Core Audio retained the queue.
            // This is a bounded safety leak rather than a dangling userData.
            return
        }
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
    }

    private func startRuntimeFailureMonitoring() {
        guard runtimeFailureTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(
            queue: Self.runtimeFailureReportingQueue
        )
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.reportLatchedRuntimeFailure()
        }
        runtimeFailureTimer = timer
        timer.activate()
    }

    private func stopRuntimeFailureMonitoring() {
        let timer = runtimeFailureTimer
        runtimeFailureTimer = nil
        timer?.cancel()
    }

    private func reportLatchedRuntimeFailure() {
        guard let status = runtimeFailureLatch.take() else { return }
        runtimeFailureHandler(
            self,
            .operation(Self.runtimeEnqueueOperation, status)
        )
    }

    private func resolveBlackHole2ChannelDeviceUID() throws -> String {
        #if DEBUG
        if let testingAudioQueueOperations {
            return try testingAudioQueueOperations
                .resolveBlackHole2ChannelDeviceUID()
        }
        #endif
        return try BlackHoleRouteVerifier.blackHole2ChannelDeviceUID()
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
        reportLatchedRuntimeFailure()
    }
    #endif
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
    func resolveBlackHole2ChannelDeviceUID() throws -> String

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

private final class BlackHoleMicrophoneOutputCallbackContext:
    @unchecked Sendable
{
    private let callbackLifetime: UnsafeMutableRawPointer
    private let source: WebRTCMacDecodedAudioSource?
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let channelCount: UInt32

    #if DEBUG
    private var testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private var renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    #endif

    init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32
    ) {
        self.callbackLifetime = callbackLifetime
        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.channelCount = channelCount
        #if DEBUG
        testingAudioQueueOperations = nil
        renderForTesting = nil
        #endif
    }

    #if DEBUG
    convenience init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32,
        testingAudioQueueOperations:
            (any BlackHoleMicrophoneOutputAudioQueueOperations)?,
        renderForTesting:
            ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    ) {
        self.init(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount
        )
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
    }
    #endif

    deinit {
        ASMacAudioQueueCallbackLifetimeDestroy(callbackLifetime)
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

    @inline(__always)
    fileprivate func fillAndEnqueue(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) -> OSStatus {
        let frameBytes = Int(channelCount) * MemoryLayout<Int16>.size
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let frameCount = capacity / frameBytes
        guard frameCount > 0 else {
            buffer.pointee.mAudioDataByteSize = 0
            return enqueueBuffer(buffer, on: queue)
        }

        let rawData = buffer.pointee.mAudioData
        memset(rawData, 0, capacity)
        let samples = rawData.assumingMemoryBound(to: Int16.self)
        #if DEBUG
        if let renderForTesting {
            _ = renderForTesting(samples, frameCount)
        } else if let source {
            _ = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        }
        #else
        if let source {
            _ = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        }
        #endif

        buffer.pointee.mAudioDataByteSize =
            UInt32(frameCount * frameBytes)
        return enqueueBuffer(buffer, on: queue)
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

    let status = callbackContext.fillAndEnqueue(
        queue: queue,
        buffer: buffer
    )
    guard status != noErr else { return }

    // This is the callback's sole failure action: one lock-free status
    // publication. Reporting, logging, stopping, freeing, and disposal remain
    // exclusively outside the realtime callback.
    callbackContext.publishRuntimeEnqueueFailure(status)
}

enum BlackHoleMicrophoneOutputError:
    LocalizedError,
    Equatable,
    Sendable
{
    case operation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .operation(let operation, let status):
            return "\(operation) failed with Core Audio status \(status)."
        }
    }
}
