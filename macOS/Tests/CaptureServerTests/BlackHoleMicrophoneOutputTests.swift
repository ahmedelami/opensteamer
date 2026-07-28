#if os(macOS) && DEBUG
import AudioToolbox
import Foundation
import XCTest
@testable import CaptureServer

@MainActor
final class BlackHoleMicrophoneOutputTests: XCTestCase {
    private static let primingFailure = OSStatus(-66_201)
    private static let allocationFailure = OSStatus(-66_202)
    private static let firstRuntimeFailure = OSStatus(-66_203)
    private static let repeatedRuntimeFailure = OSStatus(-66_204)
    private static let callbackStopFailure = OSStatus(-66_205)

    func testPrimingFailurePreventsStartCleansExactPartialQueueAndThrowsStatus() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                Self.primingFailure,
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "prime BlackHole output buffer",
                    Self.primingFailure
                )
            )
        }

        XCTAssertEqual(
            operations.selectedDeviceUIDs,
            ["BlackHole2ch_UID"]
        )
        XCTAssertEqual(operations.allocateCallCount, 2)
        XCTAssertEqual(operations.enqueueCallCount, 2)
        XCTAssertEqual(
            operations.startCallCount,
            0,
            "A failed priming enqueue must abort before AudioQueueStart."
        )
        XCTAssertEqual(
            operations.stopCallCount,
            0,
            "An unstarted queue does not require AudioQueueStop during cleanup."
        )
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)

        output.stop()
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testAllocationFailureChecksStatusAndCleansOnlyAllocatedBuffers() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            allocateStatuses: [
                noErr,
                Self.allocationFailure,
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "allocate BlackHole output buffer",
                    Self.allocationFailure
                )
            )
        }

        XCTAssertEqual(operations.allocateCallCount, 2)
        XCTAssertEqual(operations.enqueueCallCount, 1)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testCallbackFailuresLatchFirstStatusReportOffCallbackOnceAndNeverTeardownInsideCallback() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                noErr,
                noErr,
                Self.firstRuntimeFailure,
                Self.repeatedRuntimeFailure,
            ],
            reportedBufferCapacities: [
                2: 0,
            ]
        )
        let renderProbe = BlackHoleRenderProbe()
        let failureProbe = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    return false
                },
                runtimeFailureHandler: { output, error in
                    failureProbe.record(error)
                    output.stop()
                }
            )
        )

        try output.start()
        try output.start()
        let primedProgress = output.forwardingProgressSnapshot
        XCTAssertTrue(primedProgress.queueRunning)
        XCTAssertEqual(
            primedProgress.postStartCallbackCount,
            0,
            "Three priming fills must never appear as post-start progress."
        )
        XCTAssertEqual(
            operations.startCallCount,
            1,
            "Repeated start must remain idempotent."
        )
        XCTAssertEqual(operations.enqueueCallCount, 3)

        let allocatedBuffers = operations.allocatedBuffers
        XCTAssertEqual(allocatedBuffers.count, 3)
        let normalBuffer = try XCTUnwrap(allocatedBuffers.first)
        let zeroFrameBuffer = allocatedBuffers[2]
        let renderCountAfterPriming = renderProbe.count

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: normalBuffer
        )
        XCTAssertEqual(
            normalBuffer.pointee.mAudioDataByteSize,
            normalBuffer.pointee.mAudioDataBytesCapacity
        )
        XCTAssertEqual(renderProbe.count, renderCountAfterPriming + 1)

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: zeroFrameBuffer
        )
        XCTAssertEqual(zeroFrameBuffer.pointee.mAudioDataByteSize, 0)
        XCTAssertEqual(
            renderProbe.count,
            renderCountAfterPriming + 1,
            "The zero-frame branch must enqueue without invoking the native pull."
        )

        XCTAssertEqual(operations.enqueueCallCount, 5)
        XCTAssertEqual(
            failureProbe.errors.count,
            0,
            "The realtime callback may only publish to the atomic latch."
        )
        XCTAssertEqual(
            operations.stopCallCount,
            0,
            "AudioQueueStop must never run inside the realtime callback."
        )
        XCTAssertEqual(
            operations.freeBufferCallCount,
            0,
            "AudioQueueFreeBuffer must never run inside the realtime callback."
        )
        XCTAssertEqual(
            operations.disposeCallCount,
            0,
            "AudioQueueDispose must never run inside the realtime callback."
        )

        let callbackProgress = output.forwardingProgressSnapshot
        XCTAssertEqual(callbackProgress.postStartCallbackCount, 2)
        XCTAssertEqual(callbackProgress.requestedFrameCount, 480)
        XCTAssertEqual(callbackProgress.successfulPullCount, 0)
        XCTAssertEqual(callbackProgress.successfulFrameCount, 0)
        XCTAssertEqual(callbackProgress.silenceFallbackCount, 2)
        XCTAssertEqual(callbackProgress.silenceFrameCount, 480)
        XCTAssertEqual(callbackProgress.enqueueFailureCount, 2)
        XCTAssertEqual(
            callbackProgress.lastEnqueueStatus,
            Self.repeatedRuntimeFailure
        )

        output.debugReportLatchedRuntimeFailureForTesting()
        XCTAssertEqual(
            failureProbe.errors,
            [
                .operation(
                    "re-enqueue BlackHole output buffer",
                    Self.firstRuntimeFailure
                ),
            ],
            "The first callback failure must win and report off-callback exactly once."
        )
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)

        output.debugReportLatchedRuntimeFailureForTesting()
        output.stop()
        XCTAssertEqual(failureProbe.errors.count, 1)
        XCTAssertEqual(
            operations.stopCallCount,
            1,
            "Repeated reports and stop calls must remain idempotent."
        )
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testFailedDecodedPullRezerosFullCapacityAndEnqueuesFullSilence()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for index in 0..<(frameCount * 2) {
                        samples[index] = Int16((index % 2_000) + 1)
                    }
                    return false
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )

        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let enqueueCount = operations.enqueueCallCount
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )

        XCTAssertEqual(
            operations.enqueueCallCount,
            enqueueCount + 1
        )
        XCTAssertEqual(
            buffer.pointee.mAudioDataByteSize,
            buffer.pointee.mAudioDataBytesCapacity
        )
        let sampleCount =
            Int(buffer.pointee.mAudioDataByteSize)
            / MemoryLayout<Int16>.size
        let samples = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: Int16.self),
            count: sampleCount
        )
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })

        let progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 1)
        XCTAssertEqual(progress.requestedFrameCount, 480)
        XCTAssertEqual(progress.successfulPullCount, 0)
        XCTAssertEqual(progress.successfulFrameCount, 0)
        XCTAssertEqual(progress.silenceFallbackCount, 1)
        XCTAssertEqual(progress.silenceFrameCount, 480)
        XCTAssertEqual(progress.enqueueFailureCount, 0)
        output.stop()
    }

    func testSuccessfulDecodedPullPreservesPatternAndAdvancesExactFrames()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for frame in 0..<frameCount {
                        let marker = Int16(frame + 1)
                        samples[frame * 2] = marker
                        samples[frame * 2 + 1] = -marker
                    }
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )

        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        var progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 1)
        XCTAssertEqual(progress.successfulPullCount, 1)
        XCTAssertEqual(progress.successfulFrameCount, 480)
        XCTAssertEqual(progress.silenceFallbackCount, 0)

        let samples = buffer.pointee.mAudioData
            .assumingMemoryBound(to: Int16.self)
        XCTAssertEqual(samples[0], 1)
        XCTAssertEqual(samples[1], -1)
        XCTAssertEqual(samples[958], 480)
        XCTAssertEqual(samples[959], -480)

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 2)
        XCTAssertEqual(progress.requestedFrameCount, 960)
        XCTAssertEqual(progress.successfulPullCount, 2)
        XCTAssertEqual(progress.successfulFrameCount, 960)
        XCTAssertEqual(progress.enqueueFailureCount, 0)
        output.stop()
        XCTAssertFalse(
            output.forwardingProgressSnapshot.queueRunning
        )
    }

    func testStopFailureAndDeinitFenceHeldCallbackBeforeDispose() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            stopStatus: Self.callbackStopFailure
        )
        let callbackProbe = BlackHoleCallbackHoldProbe()
        let deinitProbe = BlackHoleDeinitProbe()
        let callbackReturned = DispatchSemaphore(value: 0)
        let releaseReturned = DispatchSemaphore(value: 0)
        var output: BlackHoleMicrophoneOutput? = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    callbackProbe.render(frameCount: frameCount)
                },
                deinitForTesting: {
                    deinitProbe.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try XCTUnwrap(output).start()
        let renderCountAfterPriming = callbackProbe.count
        callbackProbe.holdNextRender()

        let callbackContext = try XCTUnwrap(
            output?.debugRealtimeCallbackContextForTesting()
        )
        let callbackBuffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: callbackContext,
            queue: operations.queue,
            buffer: callbackBuffer
        )
        DispatchQueue.global(qos: .userInitiated).async {
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
            callbackReturned.signal()
        }

        XCTAssertEqual(
            callbackProbe.entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)

        let weakOutput = BlackHoleWeakOutputBox(try XCTUnwrap(output))
        let releaseBox = BlackHoleOutputReleaseBox(try XCTUnwrap(output))
        output = nil
        DispatchQueue.global(qos: .userInitiated).async {
            releaseBox.output = nil
            releaseReturned.signal()
        }

        let stopDeadline = Date().addingTimeInterval(1)
        while operations.stopCallCount == 0, Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 0)
        XCTAssertEqual(operations.activeAllocationCount, 3)
        XCTAssertEqual(
            releaseReturned.wait(timeout: .now() + .milliseconds(20)),
            .timedOut
        )
        XCTAssertEqual(
            deinitProbe.completed.wait(
                timeout: .now() + .milliseconds(20)
            ),
            .timedOut
        )

        BlackHoleMicrophoneOutput
            .debugInvokeRealtimeCallbackWithContextForTesting(
                context: callbackInvocation.context,
                queue: callbackInvocation.queue,
                buffer: callbackInvocation.buffer
            )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)
        XCTAssertEqual(operations.enqueueCallCount, 3)

        callbackProbe.releaseHeldRender()
        XCTAssertEqual(
            callbackReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            releaseReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            deinitProbe.completed.wait(timeout: .now() + .seconds(1)),
            .success
        )

        XCTAssertNil(weakOutput.output)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertEqual(operations.enqueueCallCount, 4)
        XCTAssertEqual(operations.enqueueAfterDisposeCallCount, 0)
    }
}

private final class FakeBlackHoleAudioQueueOperations:
    BlackHoleMicrophoneOutputAudioQueueOperations,
    @unchecked Sendable
{
    let queue: AudioQueueRef = OpaquePointer(bitPattern: 0xB10C)!

    private let lock = NSLock()
    private let deviceUID: String
    private let createStatus: OSStatus
    private let setDeviceStatus: OSStatus
    private let allocateStatuses: [OSStatus]
    private let enqueueStatuses: [OSStatus]
    private let startStatus: OSStatus
    private let stopStatus: OSStatus
    private let disposeStatus: OSStatus
    private let reportedBufferCapacities: [Int: UInt32]
    private var allocations: [FakeAudioQueueBufferAllocation] = []
    private var selectedDeviceUIDsStorage: [String] = []
    private var allocateCallCountStorage = 0
    private var enqueueCallCountStorage = 0
    private var startCallCountStorage = 0
    private var stopCallCountStorage = 0
    private var freeBufferCallCountStorage = 0
    private var disposeCallCountStorage = 0
    private var enqueueAfterDisposeCallCountStorage = 0
    private var queueWasDisposed = false

    init(
        deviceUID: String = "BlackHole2ch_UID",
        createStatus: OSStatus = noErr,
        setDeviceStatus: OSStatus = noErr,
        allocateStatuses: [OSStatus] = [],
        enqueueStatuses: [OSStatus] = [],
        startStatus: OSStatus = noErr,
        stopStatus: OSStatus = noErr,
        disposeStatus: OSStatus = noErr,
        reportedBufferCapacities: [Int: UInt32] = [:]
    ) {
        self.deviceUID = deviceUID
        self.createStatus = createStatus
        self.setDeviceStatus = setDeviceStatus
        self.allocateStatuses = allocateStatuses
        self.enqueueStatuses = enqueueStatuses
        self.startStatus = startStatus
        self.stopStatus = stopStatus
        self.disposeStatus = disposeStatus
        self.reportedBufferCapacities = reportedBufferCapacities
    }

    deinit {
        lock.lock()
        let allocations = self.allocations
        lock.unlock()
        for allocation in allocations {
            allocation.freeIfNeeded()
        }
    }

    var selectedDeviceUIDs: [String] {
        withLock { selectedDeviceUIDsStorage }
    }

    var allocateCallCount: Int {
        withLock { allocateCallCountStorage }
    }

    var enqueueCallCount: Int {
        withLock { enqueueCallCountStorage }
    }

    var startCallCount: Int {
        withLock { startCallCountStorage }
    }

    var stopCallCount: Int {
        withLock { stopCallCountStorage }
    }

    var freeBufferCallCount: Int {
        withLock { freeBufferCallCountStorage }
    }

    var disposeCallCount: Int {
        withLock { disposeCallCountStorage }
    }

    var enqueueAfterDisposeCallCount: Int {
        withLock { enqueueAfterDisposeCallCountStorage }
    }

    var allocatedBuffers: [AudioQueueBufferRef] {
        withLock { allocations.map(\.buffer) }
    }

    var activeAllocationCount: Int {
        withLock {
            allocations.filter { !$0.isFreed }.count
        }
    }

    func createOutputQueue() -> (
        status: OSStatus,
        queue: AudioQueueRef?
    ) {
        (createStatus, queue)
    }

    func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            selectedDeviceUIDsStorage.append(uid)
            return setDeviceStatus
        }
    }

    func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (
        status: OSStatus,
        buffer: AudioQueueBufferRef?
    ) {
        withLock {
            let index = allocateCallCountStorage
            allocateCallCountStorage += 1
            let status = index < allocateStatuses.count
                ? allocateStatuses[index]
                : noErr
            guard status == noErr else {
                return (status, nil)
            }

            let capacity = reportedBufferCapacities[index] ?? byteCount
            let allocation = FakeAudioQueueBufferAllocation(
                capacity: capacity
            )
            allocations.append(allocation)
            return (status, allocation.buffer)
        }
    }

    func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            guard !queueWasDisposed,
                  let allocation = allocations.first(where: {
                      $0.buffer == buffer
                  }),
                  !allocation.isFreed else {
                enqueueAfterDisposeCallCountStorage += 1
                return kAudio_ParamError
            }

            let index = enqueueCallCountStorage
            enqueueCallCountStorage += 1
            return index < enqueueStatuses.count
                ? enqueueStatuses[index]
                : noErr
        }
    }

    func startQueue(_ queue: AudioQueueRef) -> OSStatus {
        withLock {
            startCallCountStorage += 1
            return startStatus
        }
    }

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        withLock {
            stopCallCountStorage += 1
            return stopStatus
        }
    }

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            guard let allocation = allocations.first(where: {
                $0.buffer == buffer
            }), !allocation.isFreed else {
                return kAudio_ParamError
            }

            allocation.freeIfNeeded()
            freeBufferCallCountStorage += 1
            return noErr
        }
    }

    func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        withLock {
            disposeCallCountStorage += 1
            guard disposeStatus == noErr else {
                return disposeStatus
            }

            queueWasDisposed = true
            for allocation in allocations {
                allocation.freeIfNeeded()
            }
            return noErr
        }
    }

    private func withLock<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeAudioQueueBufferAllocation {
    let buffer: AudioQueueBufferRef
    let data: UnsafeMutableRawPointer
    private(set) var isFreed = false

    init(capacity: UInt32) {
        data = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(capacity), 1),
            alignment: MemoryLayout<Int16>.alignment
        )
        buffer = AudioQueueBufferRef.allocate(capacity: 1)
        buffer.initialize(
            to: AudioQueueBuffer(
                mAudioDataBytesCapacity: capacity,
                mAudioData: data,
                mAudioDataByteSize: 0,
                mUserData: nil,
                mPacketDescriptionCapacity: 0,
                mPacketDescriptions: nil,
                mPacketDescriptionCount: 0
            )
        )
    }

    func freeIfNeeded() {
        guard !isFreed else { return }
        isFreed = true
        buffer.deinitialize(count: 1)
        buffer.deallocate()
        data.deallocate()
    }
}

private final class BlackHoleCallbackHoldProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldHoldNextRender = false
    private var renderCountStorage = 0
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderCountStorage
    }

    func holdNextRender() {
        lock.lock()
        shouldHoldNextRender = true
        lock.unlock()
    }

    func render(frameCount _: Int) -> Bool {
        lock.lock()
        renderCountStorage += 1
        let shouldHold = shouldHoldNextRender
        shouldHoldNextRender = false
        lock.unlock()

        if shouldHold {
            entered.signal()
            release.wait()
        }
        return false
    }

    func releaseHeldRender() {
        release.signal()
    }
}

private final class BlackHoleCallbackInvocationBox: @unchecked Sendable {
    let context: UnsafeMutableRawPointer
    let queue: AudioQueueRef
    let buffer: AudioQueueBufferRef

    init(
        context: UnsafeMutableRawPointer,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        self.context = context
        self.queue = queue
        self.buffer = buffer
    }
}

private final class BlackHoleOutputReleaseBox: @unchecked Sendable {
    var output: BlackHoleMicrophoneOutput?

    init(_ output: BlackHoleMicrophoneOutput) {
        self.output = output
    }
}

private final class BlackHoleWeakOutputBox: @unchecked Sendable {
    weak var output: BlackHoleMicrophoneOutput?

    init(_ output: BlackHoleMicrophoneOutput) {
        self.output = output
    }
}

private final class BlackHoleDeinitProbe: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    func record() {
        completed.signal()
    }
}

private final class BlackHoleRenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCounts: [Int] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCounts.count
    }

    func record(frameCount: Int) {
        lock.lock()
        frameCounts.append(frameCount)
        lock.unlock()
    }
}

private final class BlackHoleRuntimeFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var errorsStorage: [BlackHoleMicrophoneOutputError] = []

    var errors: [BlackHoleMicrophoneOutputError] {
        lock.lock()
        defer { lock.unlock() }
        return errorsStorage
    }

    func record(_ error: BlackHoleMicrophoneOutputError) {
        lock.lock()
        errorsStorage.append(error)
        lock.unlock()
    }
}
#endif
