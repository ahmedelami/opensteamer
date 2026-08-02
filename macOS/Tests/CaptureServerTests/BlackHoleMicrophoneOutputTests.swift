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
    private static let disposeFailure = OSStatus(-66_206)
    private static let progressStallGraceNanoseconds: UInt64 = 100

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

    func testDisposeFailureTerminalizesQueueReleasesContextAndAllowsReplacementStart()
        throws {
        let retainer =
            BlackHoleMicrophoneOutputQueueDisposalRetainer()
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                queueDisposalRetainer: retainer,
                maximumQueueDisposalAttemptCountPerEpisode: 1,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let originalQueue = operations.queue
        let originalBuffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let enqueueCount = operations.enqueueCallCount

        output.stop()

        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertFalse(output.debugHasPendingQueueDisposalForTesting)
        XCTAssertEqual(retainer.retainedDisposalCount, 0)
        XCTAssertEqual(
            output.debugLastDisposeStatusForTesting,
            Self.disposeFailure
        )
        XCTAssertEqual(callbackContextDeinit.count, 1)
        XCTAssertEqual(
            callbackContextDeinit.completed.wait(
                timeout: .now() + .seconds(1)
            ),
            .success,
            "The retained AudioQueue callback context must be released exactly once after AudioQueueDispose returns, even when it returns an error."
        )

        XCTAssertEqual(
            operations.enqueueBuffer(
                originalBuffer,
                on: originalQueue
            ),
            kAudio_ParamError,
            "The fake terminalizes a queue immediately after AudioQueueDispose returns so a retry-after-error mutant cannot pass."
        )
        XCTAssertEqual(operations.enqueueCallCount, enqueueCount)
        output.stop()
        XCTAssertEqual(
            operations.disposeCallCount,
            1,
            "A terminal AudioQueueRef must never be disposed a second time."
        )

        try output.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "A nonzero dispose status is diagnostic only and must not globally poison replacement queue creation."
        )
        XCTAssertNotEqual(operations.queue, originalQueue)
        output.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(callbackContextDeinit.count, 2)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testFailedStartDisposeFailureReleasesContextAndAllowsLaterStart()
        throws {
        let retainer =
            BlackHoleMicrophoneOutputQueueDisposalRetainer()
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                Self.primingFailure,
            ],
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                queueDisposalRetainer: retainer,
                maximumQueueDisposalAttemptCountPerEpisode: 1,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
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

        XCTAssertEqual(operations.createCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertFalse(output.debugHasPendingQueueDisposalForTesting)
        XCTAssertEqual(retainer.retainedDisposalCount, 0)
        XCTAssertEqual(callbackContextDeinit.count, 1)

        try output.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "Failed-start cleanup must not retain a poisoned global disposal gate."
        )
        output.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(callbackContextDeinit.count, 2)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testRepeatedStopAndDeinitNeverRedisposeTerminalQueue()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [Self.disposeFailure]
        )
        let deinitProbe = BlackHoleDeinitProbe()
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        var output: BlackHoleMicrophoneOutput? = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
                deinitForTesting: {
                    deinitProbe.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output!.start()
        output!.stop()
        output!.stop()
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(callbackContextDeinit.count, 1)

        output = nil
        XCTAssertEqual(
            deinitProbe.completed.wait(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        XCTAssertEqual(
            operations.disposeCallCount,
            1,
            "Deinit after explicit stop must not retry the terminal AudioQueueRef."
        )
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testMultipleIndependentOutputsDoNotPoisonReplacementStarts()
        throws {
        let firstCallbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let secondCallbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let first = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    firstCallbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        let second = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    secondCallbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try first.start()
        first.stop()
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(firstCallbackContextDeinit.count, 1)

        try second.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "A failed dispose from one output must not block an independent replacement output."
        )
        second.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(secondCallbackContextDeinit.count, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testDisposeWaitsForEnteredCallbackBeforeReleasingContext() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [Self.disposeFailure]
        )
        let callbackProbe = BlackHoleCallbackHoldProbe()
        let contextDeinit = BlackHoleCallbackContextDeinitProbe()
        let stopReturned = DispatchSemaphore(value: 0)
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    callbackProbe.render(frameCount: frameCount)
                },
                callbackContextDeinitForTesting: {
                    contextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let renderCountAfterPriming = callbackProbe.count
        callbackProbe.holdNextRender()
        let context = try XCTUnwrap(
            output.debugRealtimeCallbackContextForTesting()
        )
        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: context,
            queue: operations.queue,
            buffer: buffer
        )
        DispatchQueue.global(qos: .userInitiated).async {
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
        }
        XCTAssertEqual(
            callbackProbe.entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)

        DispatchQueue.global(qos: .userInitiated).async {
            output.stop()
            stopReturned.signal()
        }

        let stopDeadline = Date().addingTimeInterval(1)
        while operations.stopCallCount == 0, Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 0)
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .milliseconds(20)),
            .timedOut
        )
        XCTAssertEqual(contextDeinit.count, 0)

        callbackProbe.releaseHeldRender()
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(contextDeinit.count, 1)
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

    func testProgressWatchdogToleratesContinuouslyAdvancingSilenceBeforeFirstPCM()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)

        for _ in 0..<4 {
            clock.advance(
                by: Self.progressStallGraceNanoseconds - 1
            )
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
            output.debugPollRuntimeFailureMonitoringForTesting(
                generation: generation
            )
        }
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            4
        )
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .successfulFrameCount,
            0
        )
        output.stop()
    }

    func testProgressWatchdogReportsSilentCallbackCessationBeforeFirstPCMExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        output.stop()
    }

    func testProgressWatchdogReportsMissingStartupCallbacksExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )
        output.stop()
    }

    func testProgressWatchdogAllowsDelayedFirstPCMAndThenTracksHealthyFrames()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: false)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(
                        samples: samples,
                        frameCount: frameCount
                    )
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)

        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        render.setSucceeds(true)
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .successfulFrameCount,
            960
        )
        output.stop()
    }

    func testProgressWatchdogReportsPostSuccessTimeoutExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        output.stop()
    }

    func testProgressWatchdogRefreshesOnHealthyFrameAdvances()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds - 1)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds - 1)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        output.stop()
    }

    func testStopAndRestartFencePreviousWatchdogGeneration() throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let firstGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        clock.advance(by: Self.progressStallGraceNanoseconds * 2)
        output.stop()
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: firstGeneration
        )

        try output.start()
        let secondGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        let secondBuffer = try XCTUnwrap(
            operations.allocatedBuffers.last
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: secondBuffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: secondGeneration
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: firstGeneration
        )

        XCTAssertTrue(failures.errors.isEmpty)
        output.stop()
    }

    func testEnqueueFailureWinsWhenPollRunsBetweenFailureAndProgressPublications()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                noErr,
                noErr,
                noErr,
                Self.firstRuntimeFailure,
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let interlock =
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock()
        let callbackInvocationCompleted = DispatchGroup()
        let handlerEntered = DispatchSemaphore(value: 0)
        let pollCompleted = DispatchGroup()
        let allowHandlerStop = DispatchSemaphore(value: 0)
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeEnqueueFailurePublicationInterlockForTesting:
                    interlock,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { output, error in
                    failures.record(error)
                    handlerEntered.signal()
                    allowHandlerStop.wait()
                    output.stop()
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        let callbackContext = try XCTUnwrap(
            output.debugRealtimeCallbackContextForTesting()
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: callbackContext,
            queue: operations.queue,
            buffer: buffer
        )
        render.setSucceeds(false)
        clock.advance(by: Self.progressStallGraceNanoseconds)
        interlock.armNextFailureCallback()
        callbackInvocationCompleted.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { callbackInvocationCompleted.leave() }
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
        }

        var pollStarted = false
        defer {
            withExtendedLifetime(output) {
                interlock.releaseCallback()
                callbackInvocationCompleted.wait()
                allowHandlerStop.signal()
                if pollStarted {
                    pollCompleted.wait()
                }
            }
        }

        guard interlock.waitUntilCallbackPaused(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The intended async callback did not pause after " +
                    "publishing its enqueue failure."
            )
            return
        }
        let interleavedSnapshot =
            output.forwardingProgressSnapshot
        XCTAssertEqual(interleavedSnapshot.postStartCallbackCount, 1)
        XCTAssertEqual(interleavedSnapshot.enqueueFailureCount, 0)

        pollCompleted.enter()
        pollStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { pollCompleted.leave() }
            output.debugPollRuntimeFailureMonitoringForTesting(
                generation: generation
            )
        }
        guard handlerEntered.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The failure poll did not enter the runtime handler."
            )
            return
        }
        interlock.releaseCallback()
        guard callbackInvocationCompleted.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The paused callback did not return after release."
            )
            return
        }
        allowHandlerStop.signal()
        guard pollCompleted.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The failure poll did not return after handler stop."
            )
            return
        }

        XCTAssertEqual(
            failures.errors,
            [
                .operation(
                    "re-enqueue BlackHole output buffer",
                    Self.firstRuntimeFailure
                ),
            ]
        )

        let progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 2)
        XCTAssertEqual(progress.requestedFrameCount, 960)
        XCTAssertEqual(progress.successfulPullCount, 1)
        XCTAssertEqual(progress.successfulFrameCount, 480)
        XCTAssertEqual(progress.silenceFallbackCount, 1)
        XCTAssertEqual(progress.silenceFrameCount, 480)
        XCTAssertEqual(progress.enqueueFailureCount, 1)
        XCTAssertEqual(
            progress.lastEnqueueStatus,
            Self.firstRuntimeFailure
        )
        output.stop()
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
    var queue: AudioQueueRef {
        withLock { latestQueue }
    }

    private let lock = NSLock()
    private let deviceUID: String
    private let createStatus: OSStatus
    private let setDeviceStatus: OSStatus
    private let allocateStatuses: [OSStatus]
    private let enqueueStatuses: [OSStatus]
    private let startStatus: OSStatus
    private let stopStatus: OSStatus
    private let disposeStatus: OSStatus
    private let disposeStatuses: [OSStatus]
    private let reportedBufferCapacities: [Int: UInt32]
    private var allocations: [FakeAudioQueueBufferAllocation] = []
    private var selectedDeviceUIDsStorage: [String] = []
    private var allocateCallCountStorage = 0
    private var enqueueCallCountStorage = 0
    private var startCallCountStorage = 0
    private var stopCallCountStorage = 0
    private var freeBufferCallCountStorage = 0
    private var disposeCallCountStorage = 0
    private var createCallCountStorage = 0
    private var enqueueAfterDisposeCallCountStorage = 0
    private var latestQueue: AudioQueueRef =
        OpaquePointer(bitPattern: 0xB10C)!
    private var disposedQueues: Set<UInt> = []

    init(
        deviceUID: String = "BlackHole2ch_UID",
        createStatus: OSStatus = noErr,
        setDeviceStatus: OSStatus = noErr,
        allocateStatuses: [OSStatus] = [],
        enqueueStatuses: [OSStatus] = [],
        startStatus: OSStatus = noErr,
        stopStatus: OSStatus = noErr,
        disposeStatus: OSStatus = noErr,
        disposeStatuses: [OSStatus] = [],
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
        self.disposeStatuses = disposeStatuses
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

    var createCallCount: Int {
        withLock { createCallCountStorage }
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
        withLock {
            createCallCountStorage += 1
            allocations.removeAll(where: { $0.isFreed })
            let identity = UInt(0xB10C + createCallCountStorage * 0x100)
            latestQueue = OpaquePointer(bitPattern: identity)!
            return (createStatus, latestQueue)
        }
    }

    func setCurrentDevice(
        _ uid: String,
        on _: AudioQueueRef
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
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity) else {
                return (kAudio_ParamError, nil)
            }
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
                queueIdentity: identity,
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
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity),
                  let allocation = allocations.first(where: {
                      $0.buffer == buffer
                          && $0.queueIdentity == identity
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
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return kAudio_ParamError
            }
            startCallCountStorage += 1
            return startStatus
        }
    }

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate _: Bool
    ) -> OSStatus {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return kAudio_ParamError
            }
            stopCallCountStorage += 1
            return stopStatus
        }
    }

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            let identity = Self.identity(queue)
            guard let allocation = allocations.first(where: {
                $0.buffer == buffer
                    && $0.queueIdentity == identity
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
        immediate _: Bool
    ) -> OSStatus {
        withLock {
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity) else {
                preconditionFailure(
                    "AudioQueueDispose was called twice for terminal queue \(identity)"
                )
            }

            let index = disposeCallCountStorage
            disposeCallCountStorage += 1
            let status =
                index < disposeStatuses.count
                    ? disposeStatuses[index]
                    : disposeStatus
            disposedQueues.insert(identity)
            for allocation in allocations
                where allocation.queueIdentity == identity {
                allocation.freeIfNeeded()
            }
            return status
        }
    }

    private static func identity(
        _ queue: AudioQueueRef
    ) -> UInt {
        UInt(bitPattern: queue)
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
    let queueIdentity: UInt
    let buffer: AudioQueueBufferRef
    let data: UnsafeMutableRawPointer
    private(set) var isFreed = false

    init(queueIdentity: UInt, capacity: UInt32) {
        self.queueIdentity = queueIdentity
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

private final class BlackHoleManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: UInt64) {
        lock.lock()
        value &+= delta
        lock.unlock()
    }
}

private final class BlackHoleRenderOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeds: Bool

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func setSucceeds(_ succeeds: Bool) {
        lock.lock()
        self.succeeds = succeeds
        lock.unlock()
    }

    func render(
        samples _: UnsafeMutablePointer<Int16>,
        frameCount _: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeds
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

private final class BlackHoleCallbackContextDeinitProbe:
    @unchecked Sendable
{
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    func record() {
        lock.lock()
        countStorage += 1
        lock.unlock()
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
