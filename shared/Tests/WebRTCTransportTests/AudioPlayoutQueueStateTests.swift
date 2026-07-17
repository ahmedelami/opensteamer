@testable import WebRTCTransport
import AVFoundation
import XCTest

#if os(macOS)
final class AudioPlayoutQueueStateTests: XCTestCase {
    func testProductionPolicyWaitsForSixtyMillisecondsBeforeStarting() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)

        let first = state.enqueue(frameCount: 960, renderedFrame: nil)
        let second = state.enqueue(frameCount: 960, renderedFrame: nil)
        let third = state.enqueue(frameCount: 960, renderedFrame: nil)

        XCTAssertTrue(first.accepted)
        XCTAssertFalse(first.shouldStartPlayback)
        XCTAssertFalse(second.shouldStartPlayback)
        XCTAssertTrue(third.shouldStartPlayback)
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.queuedFrames, 2_880)
    }

    func testRenderedProgressPreventsFalseOverflowAtExactQueueLimit() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        let initial = state.enqueue(frameCount: 5_760, renderedFrame: nil)
        XCTAssertTrue(initial.shouldStartPlayback)

        let generation = state.generation
        let boundary = state.enqueue(frameCount: 480, renderedFrame: 480)

        XCTAssertTrue(boundary.accepted)
        XCTAssertFalse(boundary.shouldResetPlayer)
        XCTAssertEqual(boundary.scheduleStartFrame, 5_760)
        XCTAssertEqual(state.queuedFrames, 5_760)
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.overflowDropCount, 0)
    }

    func testOverflowDropsNewestWithoutResettingQueuedAudio() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        _ = state.enqueue(frameCount: 5_760, renderedFrame: nil)
        let generation = state.generation

        let overflow = state.enqueue(frameCount: 960, renderedFrame: 0)

        XCTAssertFalse(overflow.accepted)
        XCTAssertFalse(overflow.shouldResetPlayer)
        XCTAssertEqual(state.queuedFrames, 5_760)
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.overflowDropCount, 1)
        XCTAssertEqual(state.overflowDroppedFrames, 960)
    }

    func testExactBoundaryExtensionWinsBeforeFinalCompletion() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        _ = state.enqueue(frameCount: 2_880, renderedFrame: nil)
        let generation = state.generation

        let extensionDecision = state.enqueue(
            frameCount: 960,
            renderedFrame: 2_880
        )
        let oldFinalCompletion = state.completeBuffer(
            endingAt: 2_880,
            generation: generation
        )

        XCTAssertTrue(extensionDecision.accepted)
        XCTAssertFalse(extensionDecision.shouldResetPlayer)
        XCTAssertFalse(extensionDecision.shouldStartPlayback)
        XCTAssertEqual(oldFinalCompletion, .none)
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.queuedFrames, 960)
        XCTAssertEqual(state.generation, generation)
    }

    func testFinalCompletionRebuffersAndRejectsStaleCallbacks() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        _ = state.enqueue(frameCount: 2_880, renderedFrame: nil)
        let completedGeneration = state.generation

        let completion = state.completeBuffer(
            endingAt: 2_880,
            generation: completedGeneration
        )
        let staleCompletion = state.completeBuffer(
            endingAt: 2_880,
            generation: completedGeneration
        )

        XCTAssertEqual(completion, .rebuffer)
        XCTAssertEqual(staleCompletion, .none)
        XCTAssertEqual(state.phase, .buffering)
        XCTAssertEqual(state.queuedFrames, 0)
        XCTAssertEqual(state.underrunCount, 1)
        XCTAssertEqual(state.rebufferCount, 1)
        XCTAssertEqual(state.staleCompletionCount, 1)

        XCTAssertFalse(state.enqueue(frameCount: 960, renderedFrame: nil).shouldStartPlayback)
        XCTAssertFalse(state.enqueue(frameCount: 960, renderedFrame: nil).shouldStartPlayback)
        XCTAssertTrue(state.enqueue(frameCount: 960, renderedFrame: nil).shouldStartPlayback)
    }

    func testLateArrivalAfterRenderedSilenceResetsAndRebuffers() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        _ = state.enqueue(frameCount: 2_880, renderedFrame: nil)
        let drainedGeneration = state.generation

        let lateArrival = state.enqueue(frameCount: 960, renderedFrame: 3_360)

        XCTAssertTrue(lateArrival.accepted)
        XCTAssertTrue(lateArrival.shouldResetPlayer)
        XCTAssertFalse(lateArrival.shouldStartPlayback)
        XCTAssertNotEqual(state.generation, drainedGeneration)
        XCTAssertEqual(state.underrunCount, 1)
        XCTAssertEqual(state.rebufferCount, 1)
        XCTAssertEqual(state.queuedFrames, 960)
        XCTAssertFalse(state.enqueue(frameCount: 960, renderedFrame: nil).shouldStartPlayback)
        XCTAssertTrue(state.enqueue(frameCount: 960, renderedFrame: nil).shouldStartPlayback)
    }

    func testMeasuredCaptureJitterRemainsBuffered() {
        var state = AudioPlayoutQueueState()
        state.setEnabled(true)
        let arrivalMilliseconds = [0.0, 20.0, 40.0, 71.9, 80.0, 100.0, 120.0]
        var playbackStartMilliseconds: Double?

        for arrival in arrivalMilliseconds {
            let renderedFrame: Int64?
            if let playbackStartMilliseconds {
                renderedFrame = Int64(
                    ((arrival - playbackStartMilliseconds) * 48).rounded(.down)
                )
            } else {
                renderedFrame = nil
            }
            let decision = state.enqueue(
                frameCount: 960,
                renderedFrame: renderedFrame
            )
            XCTAssertTrue(decision.accepted)
            XCTAssertFalse(decision.shouldResetPlayer)
            if decision.shouldStartPlayback {
                playbackStartMilliseconds = arrival
            }
        }

        XCTAssertEqual(state.underrunCount, 0)
        XCTAssertEqual(state.rebufferCount, 0)
        XCTAssertEqual(state.overflowDropCount, 0)
        XCTAssertEqual(state.phase, .playing)
        XCTAssertGreaterThan(state.queuedFrames, 0)
    }

    func testInvalidLastRenderTimeNeverInvokesPlayerTimeResolver() {
        let invalidNodeTime = AVAudioTime()
        var resolverWasInvoked = false

        let sampleTime = MacExternalAudioCapturer.renderedSampleTime(
            from: invalidNodeTime
        ) { _ in
            resolverWasInvoked = true
            return AVAudioTime(sampleTime: 1, atRate: 48_000)
        }

        XCTAssertFalse(invalidNodeTime.isSampleTimeValid)
        XCTAssertFalse(invalidNodeTime.isHostTimeValid)
        XCTAssertNil(sampleTime)
        XCTAssertFalse(resolverWasInvoked)
    }

    func testValidLastRenderTimeUsesResolvedNonnegativeSampleTime() {
        let nodeTime = AVAudioTime(sampleTime: 12, atRate: 48_000)

        let sampleTime = MacExternalAudioCapturer.renderedSampleTime(
            from: nodeTime
        ) { _ in
            AVAudioTime(sampleTime: 4_321, atRate: 48_000)
        }

        XCTAssertEqual(sampleTime, 4_321)
    }
}
#endif
