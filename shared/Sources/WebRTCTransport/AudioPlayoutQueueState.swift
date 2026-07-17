import Foundation

#if os(macOS)
struct AudioPlayoutQueueState: Sendable {
    static let prebufferFrames: Int64 = 2_880
    static let maximumQueuedFrames: Int64 = 5_760

    enum Phase: Equatable, Sendable {
        case disabled
        case buffering
        case playing
    }

    struct EnqueueDecision: Equatable, Sendable {
        let accepted: Bool
        let scheduleStartFrame: Int64?
        let shouldStartPlayback: Bool
        let shouldResetPlayer: Bool
    }

    enum CompletionDecision: Equatable, Sendable {
        case none
        case rebuffer
    }

    private(set) var phase: Phase = .disabled
    private(set) var generation: UInt64 = 0
    private(set) var scheduledEndFrame: Int64 = 0
    private(set) var renderedFrame: Int64 = 0
    private(set) var queueHighWaterFrames: Int64 = 0
    private(set) var underrunCount = 0
    private(set) var rebufferCount = 0
    private(set) var overflowDropCount = 0
    private(set) var overflowDroppedFrames: Int64 = 0
    private(set) var lifecycleDiscardedFrames: Int64 = 0
    private(set) var staleCompletionCount = 0

    var queuedFrames: Int64 {
        max(0, scheduledEndFrame - renderedFrame)
    }

    mutating func setEnabled(
        _ enabled: Bool,
        renderedFrame observedRenderedFrame: Int64? = nil
    ) {
        if enabled {
            guard phase == .disabled else { return }
            resetTimeline(phase: .buffering, countDiscardedFrames: false)
        } else {
            guard phase != .disabled else { return }
            observeRenderedFrame(observedRenderedFrame)
            resetTimeline(phase: .disabled, countDiscardedFrames: true)
        }
    }

    mutating func resetForLifecycle(renderedFrame observedRenderedFrame: Int64? = nil) {
        observeRenderedFrame(observedRenderedFrame)
        let nextPhase: Phase = phase == .disabled ? .disabled : .buffering
        resetTimeline(phase: nextPhase, countDiscardedFrames: true)
    }

    mutating func enqueue(
        frameCount: Int64,
        renderedFrame observedRenderedFrame: Int64?
    ) -> EnqueueDecision {
        guard phase != .disabled, frameCount > 0 else {
            return EnqueueDecision(
                accepted: false,
                scheduleStartFrame: nil,
                shouldStartPlayback: false,
                shouldResetPlayer: false
            )
        }

        var shouldResetPlayer = false
        if phase == .playing, let observedRenderedFrame {
            renderedFrame = max(renderedFrame, observedRenderedFrame)
            if renderedFrame > scheduledEndFrame {
                beginRebuffering()
                shouldResetPlayer = true
            }
        }

        guard frameCount <= Self.maximumQueuedFrames,
              queuedFrames <= Self.maximumQueuedFrames - frameCount else {
            overflowDropCount += 1
            overflowDroppedFrames += frameCount
            return EnqueueDecision(
                accepted: false,
                scheduleStartFrame: nil,
                shouldStartPlayback: false,
                shouldResetPlayer: shouldResetPlayer
            )
        }

        let scheduleStartFrame = scheduledEndFrame
        scheduledEndFrame += frameCount
        queueHighWaterFrames = max(queueHighWaterFrames, queuedFrames)

        let shouldStartPlayback = phase == .buffering
            && queuedFrames >= Self.prebufferFrames
        if shouldStartPlayback {
            phase = .playing
        }
        return EnqueueDecision(
            accepted: true,
            scheduleStartFrame: scheduleStartFrame,
            shouldStartPlayback: shouldStartPlayback,
            shouldResetPlayer: shouldResetPlayer
        )
    }

    mutating func completeBuffer(
        endingAt endFrame: Int64,
        generation callbackGeneration: UInt64
    ) -> CompletionDecision {
        guard callbackGeneration == generation else {
            staleCompletionCount += 1
            return .none
        }
        guard phase == .playing else { return .none }

        renderedFrame = max(renderedFrame, endFrame)
        guard endFrame >= scheduledEndFrame else { return .none }

        beginRebuffering()
        return .rebuffer
    }

    private mutating func beginRebuffering() {
        underrunCount += 1
        rebufferCount += 1
        resetTimeline(phase: .buffering, countDiscardedFrames: false)
    }

    private mutating func observeRenderedFrame(_ observedRenderedFrame: Int64?) {
        guard let observedRenderedFrame else { return }
        renderedFrame = max(renderedFrame, observedRenderedFrame)
    }

    private mutating func resetTimeline(
        phase nextPhase: Phase,
        countDiscardedFrames: Bool
    ) {
        if countDiscardedFrames {
            lifecycleDiscardedFrames += queuedFrames
        }
        generation &+= 1
        phase = nextPhase
        scheduledEndFrame = 0
        renderedFrame = 0
    }
}
#endif
