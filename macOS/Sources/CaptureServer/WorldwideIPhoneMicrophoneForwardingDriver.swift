import CaptureCore
import Foundation

enum WorldwideIPhoneMicrophoneForwardingPolicy:
    String,
    Equatable,
    Sendable
{
    case enabled
    case suppressedForLANCoexistence
}

enum WorldwideIPhoneMicrophoneForwardingPhase:
    String,
    Equatable,
    Sendable
{
    case waitingForMonitor
    case monitoringFailed
    case waitingForDevice
    case waitingForPeer
    case waitingForTransport
    case waitingForTrack
    case starting
    case admittingTrack
    case checkingReadiness
    case awaitingFrames
    case forwardingReady
    case forwardingHealthy
    case outputUnavailable
    case startFailed
    case admissionFailed
    case readinessFailed
    case sourceMediaStalled
    case formatUnsafe
    case sharedClockUnsafe
    case runtimeFailed
    case suppressedForLANCoexistence
    case stopped
}

enum WorldwideIPhoneMicrophoneForwardingFailureCategory:
    String,
    Equatable,
    Sendable
{
    case monitoringFailed
    case outputUnavailable
    case startFailed
    case admissionFailed
    case readinessFailed
    case sourceMediaStalled
    case formatUnsafe
    case sharedClockUnsafe
    case runtimeEnqueueFailed
    case runtimeProgressStalled
}

struct WorldwideIPhoneMicrophoneForwardingKey:
    Equatable,
    Hashable,
    Sendable
{
    let monitorEpoch: UUID
    let deviceGeneration: UInt64
    let peerGeneration: UInt64
    let transportAuthorizationEpoch: UInt64
    let trackGeneration: UInt64
}

struct WorldwideIPhoneMicrophoneForwardingHostSnapshot:
    Equatable,
    Sendable
{
    let policy: WorldwideIPhoneMicrophoneForwardingPolicy
    let phase: WorldwideIPhoneMicrophoneForwardingPhase
    let monitorEpoch: UUID?
    let deviceGeneration: UInt64
    let deviceUID: String?
    let sinkDeviceUID: String?
    let deviceAvailable: Bool
    let currentKey: WorldwideIPhoneMicrophoneForwardingKey?
    let lastAttemptedKey: WorldwideIPhoneMicrophoneForwardingKey?
    let peerGeneration: UInt64
    let transportAuthorizationEpoch: UInt64
    let transportAuthorized: Bool
    let trackGeneration: UInt64
    let currentAttemptID: UUID?
    let lastAttemptID: UUID?
    let exactTrackAdmitted: Bool
    let queueRunning: Bool
    let progress: BlackHoleMicrophoneOutputProgressSnapshot
    let inboundMediaSampleSequence: UInt64
    let inboundMediaAdvancementCount: UInt64
    let consecutiveStaleInboundMediaSamples: Int
    let inboundMediaFresh: Bool
    let lastFailureCategory:
        WorldwideIPhoneMicrophoneForwardingFailureCategory?

    var hiddenWriterSelectionProven: Bool {
        deviceAvailable
            && sinkDeviceUID != nil
            && queueRunning
    }

    static func inactive(
        policy: WorldwideIPhoneMicrophoneForwardingPolicy
    ) -> Self {
        Self(
            policy: policy,
            phase: policy == .suppressedForLANCoexistence
                ? .suppressedForLANCoexistence
                : .waitingForPeer,
            monitorEpoch: nil,
            deviceGeneration: 0,
            deviceUID: nil,
            sinkDeviceUID: nil,
            deviceAvailable: false,
            currentKey: nil,
            lastAttemptedKey: nil,
            peerGeneration: 0,
            transportAuthorizationEpoch: 0,
            transportAuthorized: false,
            trackGeneration: 0,
            currentAttemptID: nil,
            lastAttemptID: nil,
            exactTrackAdmitted: false,
            queueRunning: false,
            progress: .zero,
            inboundMediaSampleSequence: 0,
            inboundMediaAdvancementCount: 0,
            consecutiveStaleInboundMediaSamples: 0,
            inboundMediaFresh: false,
            lastFailureCategory: nil
        )
    }
}

enum WorldwideIPhoneMicrophoneForwardingProgressEvaluator {
    static func isReady(
        _ progress: BlackHoleMicrophoneOutputProgressSnapshot
    ) -> Bool {
        progress.queueRunning
            && progress.enqueueFailureCount == 0
            && progress.successfulPullCount > 0
            && progress.successfulFrameCount > 0
    }

    static func provesContinuingHealth(
        previous: BlackHoleMicrophoneOutputProgressSnapshot,
        current: BlackHoleMicrophoneOutputProgressSnapshot
    ) -> Bool {
        isReady(previous)
            && isReady(current)
            && current.postStartCallbackCount
                > previous.postStartCallbackCount
            && current.successfulFrameCount
                > previous.successfulFrameCount
    }
}

struct WorldwideIPhoneMicrophoneInboundMediaWatermark:
    Equatable,
    Sendable
{
    let packetsReceived: UInt64?
    let bytesReceived: UInt64?
    let jitterBufferEmittedCount: UInt64?
    let totalSamplesReceived: UInt64?

    func isContinuous(
        from previous: Self?
    ) -> Bool {
        guard let previous else { return true }
        return !Self.regressed(
            current: packetsReceived,
            previous: previous.packetsReceived
        ) && !Self.regressed(
            current: bytesReceived,
            previous: previous.bytesReceived
        ) && !Self.regressed(
            current: jitterBufferEmittedCount,
            previous: previous.jitterBufferEmittedCount
        ) && !Self.regressed(
            current: totalSamplesReceived,
            previous: previous.totalSamplesReceived
        )
    }

    func advances(
        from previous: Self?
    ) -> Bool {
        guard let previous else { return false }
        return Self.advanced(
            current: packetsReceived,
            previous: previous.packetsReceived
        ) || Self.advanced(
            current: bytesReceived,
            previous: previous.bytesReceived
        )
    }

    func preservingMaximums(
        from previous: Self?
    ) -> Self {
        guard let previous else { return self }
        return Self(
            packetsReceived: Self.maximum(
                previous.packetsReceived,
                packetsReceived
            ),
            bytesReceived: Self.maximum(
                previous.bytesReceived,
                bytesReceived
            ),
            jitterBufferEmittedCount: Self.maximum(
                previous.jitterBufferEmittedCount,
                jitterBufferEmittedCount
            ),
            totalSamplesReceived: Self.maximum(
                previous.totalSamplesReceived,
                totalSamplesReceived
            )
        )
    }

    private static func advanced(
        current: UInt64?,
        previous: UInt64?
    ) -> Bool {
        guard let current, let previous else { return false }
        return current > previous
    }

    private static func regressed(
        current: UInt64?,
        previous: UInt64?
    ) -> Bool {
        guard let current, let previous else { return false }
        return current < previous
    }

    private static func maximum(
        _ lhs: UInt64?,
        _ rhs: UInt64?
    ) -> UInt64? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?):
            max(lhs, rhs)
        case (let value?, nil), (nil, let value?):
            value
        case (nil, nil):
            nil
        }
    }
}

/// Actor-owned, generation-keyed driver for the Mac microphone forwarding lane.
///
/// Public methods inherit the caller's actor. Every suspension revalidates the
/// complete key and exact peer, track, and output objects before continuing.
final class WorldwideIPhoneMicrophoneForwardingDriver<
    Peer: AnyObject & Sendable,
    Track: AnyObject & Sendable
> {
    typealias OutputFactory =
        @Sendable (
            Peer,
            BlackHoleDeviceEndpointIdentity
        ) -> (any WorldwideIPhoneMicrophoneOutput)?
    typealias OutputStarter =
        @Sendable (
            any WorldwideIPhoneMicrophoneOutput
        ) async throws -> Void
    typealias Admission =
        @Sendable (Peer, Track) async throws -> Void
    typealias TrackDisabler =
        @Sendable (Track) -> Void
    typealias ReadinessSleep =
        @Sendable () async throws -> Void
    typealias MonotonicNow = @Sendable () -> UInt64
    typealias MediaFreshnessDeadlineSleep =
        @Sendable (_ deadlineNanoseconds: UInt64) async throws -> Void
    typealias SharedClockFailureHandler =
        @Sendable (
            WorldwideIPhoneMicrophoneForwardingKey,
            BlackHoleFaceTimeClockRejection
        ) async -> Void
    typealias FormatFailureHandler =
        @Sendable (
            WorldwideIPhoneMicrophoneForwardingKey,
            BlackHoleMicrophoneOutputFormatRejection
        ) async -> Void

    private struct Candidate {
        let key: WorldwideIPhoneMicrophoneForwardingKey
        let peer: Peer
        let track: Track
        let sinkEndpoint: BlackHoleDeviceEndpointIdentity
    }

    private struct InboundMediaSample {
        let sequence: UInt64
        let peerGeneration: UInt64
        let trackGeneration: UInt64
        let watermark:
            WorldwideIPhoneMicrophoneInboundMediaWatermark?
    }

    private final class Attempt {
        let id: UUID
        let key: WorldwideIPhoneMicrophoneForwardingKey
        let peer: Peer
        let track: Track
        let sinkEndpoint: BlackHoleDeviceEndpointIdentity
        let output: any WorldwideIPhoneMicrophoneOutput
        var exactTrackAdmitted = false
        var deferredReadyProgress:
            BlackHoleMicrophoneOutputProgressSnapshot?
        var sinkContinuingHealthProven = false
        var lastInboundMediaWatermark:
            WorldwideIPhoneMicrophoneInboundMediaWatermark?
        var lastInboundMediaSampleSequence: UInt64
        var inboundMediaAdvancementCount: UInt64 = 0
        var consecutiveStaleInboundMediaSamples = 0
        var requiresFreshInboundMediaAdvance: Bool
        var mediaFreshnessDeadlineNanoseconds: UInt64?
        var mediaFreshnessWatchdogGeneration: UInt64 = 0

        init(
            id: UUID,
            candidate: Candidate,
            output: any WorldwideIPhoneMicrophoneOutput,
            baselineInboundMediaSample: InboundMediaSample?,
            requiresFreshInboundMediaAdvance: Bool
        ) {
            self.id = id
            key = candidate.key
            peer = candidate.peer
            track = candidate.track
            sinkEndpoint = candidate.sinkEndpoint
            self.output = output
            lastInboundMediaWatermark =
                baselineInboundMediaSample?.watermark
            lastInboundMediaSampleSequence =
                baselineInboundMediaSample?.sequence ?? 0
            self.requiresFreshInboundMediaAdvance =
                requiresFreshInboundMediaAdvance
        }
    }

    private let policy: WorldwideIPhoneMicrophoneForwardingPolicy
    private let makeOutput: OutputFactory
    private let startOutput: OutputStarter
    private let admit: Admission
    private let disableTrack: TrackDisabler
    private let readinessSleep: ReadinessSleep
    private let retrySleep: ReadinessSleep
    private let readinessSampleLimit: Int
    private let maximumStaleInboundMediaSamples: Int
    private let mediaFreshnessTimeoutNanoseconds: UInt64
    private let mediaFreshnessNow: MonotonicNow
    private let mediaFreshnessDeadlineSleep:
        MediaFreshnessDeadlineSleep
    private let maximumAttemptCountPerKey: Int
    private let makeAttemptID: @Sendable () -> UUID
    private let sharedClockFailureHandler:
        SharedClockFailureHandler
    private let formatFailureHandler:
        FormatFailureHandler

    private var activeMonitorEpoch: UUID?
    private var monitorSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var monitoringFailed = false

    private var peer: Peer?
    private var peerGeneration: UInt64 = 0
    private var transportAuthorizationEpoch: UInt64 = 0
    private var transportAuthorized = false
    private var track: Track?
    private var trackGeneration: UInt64 = 0
    private var inboundMediaSampleSequence: UInt64 = 0
    private var latestInboundMediaSample: InboundMediaSample?

    private var currentAttempt: Attempt?
    private struct AttemptHistory {
        var count: Int
        var mayRetry: Bool
    }

    private var attemptHistory:
        [WorldwideIPhoneMicrophoneForwardingKey: AttemptHistory] = [:]
    private var attemptedKeyOrder:
        [WorldwideIPhoneMicrophoneForwardingKey] = []
    private var lastAttemptedKey:
        WorldwideIPhoneMicrophoneForwardingKey?
    private var lastAttemptID: UUID?
    private var lastFailureCategory:
        WorldwideIPhoneMicrophoneForwardingFailureCategory?
    private var preserveSharedClockUnsafePhaseUntilPeerOrPairChanges =
        false
    private var preserveFormatUnsafePhaseUntilPeerOrPairChanges =
        false

    private var phase: WorldwideIPhoneMicrophoneForwardingPhase
    private var isDriving = false
    private var redriveRequested = false
    private var isStopped = false
    private var mediaFreshnessWatchdogTask: Task<Void, Never>?

    init(
        policy: WorldwideIPhoneMicrophoneForwardingPolicy,
        makeOutput: @escaping OutputFactory,
        startOutput: @escaping OutputStarter,
        admit: @escaping Admission,
        disableTrack: @escaping TrackDisabler,
        readinessSleep: @escaping ReadinessSleep = {
            try await Task.sleep(for: .milliseconds(20))
        },
        readinessSampleLimit: Int = 50,
        maximumStaleInboundMediaSamples: Int = 3,
        mediaFreshnessTimeoutNanoseconds: UInt64 = 3_000_000_000,
        mediaFreshnessNow: @escaping MonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        mediaFreshnessDeadlineSleep:
            @escaping MediaFreshnessDeadlineSleep = { deadline in
                while true {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { return }
                    try await Task.sleep(
                        nanoseconds: deadline - now
                    )
                }
            },
        retrySleep: @escaping ReadinessSleep = {
            try await Task.sleep(for: .milliseconds(100))
        },
        maximumAttemptCountPerKey: Int = 3,
        makeAttemptID: @escaping @Sendable () -> UUID = {
            UUID()
        },
        sharedClockFailureHandler:
            @escaping SharedClockFailureHandler = { _, _ in
        },
        formatFailureHandler:
            @escaping FormatFailureHandler = { _, _ in
        }
    ) {
        self.policy = policy
        self.makeOutput = makeOutput
        self.startOutput = startOutput
        self.admit = admit
        self.disableTrack = disableTrack
        self.readinessSleep = readinessSleep
        self.retrySleep = retrySleep
        self.readinessSampleLimit = max(2, readinessSampleLimit)
        self.maximumStaleInboundMediaSamples = max(
            1,
            maximumStaleInboundMediaSamples
        )
        self.mediaFreshnessTimeoutNanoseconds = max(
            1,
            mediaFreshnessTimeoutNanoseconds
        )
        self.mediaFreshnessNow = mediaFreshnessNow
        self.mediaFreshnessDeadlineSleep =
            mediaFreshnessDeadlineSleep
        self.maximumAttemptCountPerKey = max(
            1,
            maximumAttemptCountPerKey
        )
        self.makeAttemptID = makeAttemptID
        self.sharedClockFailureHandler =
            sharedClockFailureHandler
        self.formatFailureHandler = formatFailureHandler
        phase = policy == .suppressedForLANCoexistence
            ? .suppressedForLANCoexistence
            : .waitingForMonitor
    }

    deinit {
        mediaFreshnessWatchdogTask?.cancel()
    }

    func beginMonitoring(
        isolation: isolated (any Actor)? = #isolation,
        epoch: UUID
    ) {
        guard !isStopped,
              policy == .enabled,
              activeMonitorEpoch != epoch else {
            return
        }

        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        invalidateCurrentAttempt()
        activeMonitorEpoch = epoch
        monitorSnapshot = nil
        monitoringFailed = false
        disableCurrentTrack()
        phase = .waitingForMonitor
        redriveRequested = true
    }

    func monitoringDidFail(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped, policy == .enabled else { return }
        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        invalidateCurrentAttempt()
        monitoringFailed = true
        monitorSnapshot = nil
        disableCurrentTrack()
        lastFailureCategory = .monitoringFailed
        phase = .monitoringFailed
        redriveRequested = true
    }

    func updateDeviceSnapshot(
        isolation: isolated (any Actor)? = #isolation,
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) async {
        guard !isStopped,
              policy == .enabled,
              snapshot.monitorEpoch == activeMonitorEpoch else {
            return
        }
        if let current = monitorSnapshot {
            guard snapshot.deviceGeneration
                    > current.deviceGeneration else {
                return
            }
        }

        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        invalidateCurrentAttempt()
        monitorSnapshot = snapshot
        monitoringFailed = false
        if !snapshot.isAvailable {
            disableCurrentTrack()
        }
        redriveRequested = true
        await drive(isolation: isolation)
    }

    func replacePeer(
        isolation: isolated (any Actor)? = #isolation,
        peer: Peer,
        peerGeneration: UInt64
    ) {
        guard !isStopped else { return }
        if self.peer === peer,
           self.peerGeneration == peerGeneration {
            return
        }

        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        self.peer = peer
        self.peerGeneration = peerGeneration
        latestInboundMediaSample = nil
        transportAuthorized = false
        redriveRequested = true
        updateIneligiblePhase()
    }

    func clearPeer(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped else { return }
        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        peer = nil
        latestInboundMediaSample = nil
        transportAuthorized = false
        redriveRequested = true
        updateIneligiblePhase()
    }

    func authorizeTransport(
        isolation: isolated (any Actor)? = #isolation,
        peer: Peer,
        peerGeneration: UInt64
    ) async {
        guard !isStopped else { return }
        guard policy == .enabled else {
            disableCurrentTrack()
            phase = .suppressedForLANCoexistence
            return
        }
        guard self.peer === peer,
              self.peerGeneration == peerGeneration else {
            return
        }
        guard !transportAuthorized else {
            return
        }

        transportAuthorizationEpoch = Self.nextNonzero(
            transportAuthorizationEpoch
        )
        transportAuthorized = true
        redriveRequested = true
        await drive(isolation: isolation)
    }

    func invalidateTransport(
        isolation: isolated (any Actor)? = #isolation,
        preservingSharedClockUnsafeFailure: Bool = false,
        preservingFormatUnsafeFailure: Bool = false
    ) {
        guard !isStopped else { return }
        if preservingSharedClockUnsafeFailure,
           phase == .sharedClockUnsafe,
           lastFailureCategory == .sharedClockUnsafe {
            preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = true
        }
        if preservingFormatUnsafeFailure,
           phase == .formatUnsafe,
           lastFailureCategory == .formatUnsafe {
            preserveFormatUnsafePhaseUntilPeerOrPairChanges = true
        }
        transportAuthorized = false
        latestInboundMediaSample = nil
        invalidateCurrentAttempt()
        disableCurrentTrack()
        redriveRequested = true
        updateIneligiblePhase()
    }

    func installTrack(
        isolation: isolated (any Actor)? = #isolation,
        _ track: Track
    ) async {
        guard !isStopped else {
            disableTrack(track)
            return
        }

        if self.track === track {
            if policy == .suppressedForLANCoexistence
                || !transportAuthorized {
                disableTrack(track)
            }
            return
        }

        invalidateCurrentAttempt()
        disableCurrentTrack()
        self.track = track
        trackGeneration = Self.nextNonzero(trackGeneration)
        latestInboundMediaSample = nil
        disableTrack(track)
        redriveRequested = true

        guard policy == .enabled else {
            phase = .suppressedForLANCoexistence
            return
        }
        await drive(isolation: isolation)
    }

    func clearTrack(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped else { return }
        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        latestInboundMediaSample = nil
        redriveRequested = true
        updateIneligiblePhase()
    }

    func updateInboundMediaFreshness(
        isolation: isolated (any Actor)? = #isolation,
        peer sourcePeer: Peer,
        peerGeneration sourcePeerGeneration: UInt64,
        watermark: WorldwideIPhoneMicrophoneInboundMediaWatermark?
    ) async {
        guard !isStopped,
              self.peer === sourcePeer,
              peerGeneration == sourcePeerGeneration,
              sourcePeerGeneration > 0 else {
            return
        }

        inboundMediaSampleSequence = Self.nextNonzero(
            inboundMediaSampleSequence
        )
        let previousSample = latestInboundMediaSample
        let sample = InboundMediaSample(
            sequence: inboundMediaSampleSequence,
            peerGeneration: sourcePeerGeneration,
            trackGeneration: trackGeneration,
            watermark: watermark
        )
        latestInboundMediaSample = sample

        guard let attempt = currentAttempt,
              candidateStillOwnsAttempt(attempt),
              attempt.exactTrackAdmitted,
              attempt.peer === sourcePeer,
              attempt.key.peerGeneration == sourcePeerGeneration,
              sample.trackGeneration == attempt.key.trackGeneration,
              sample.sequence > attempt.lastInboundMediaSampleSequence else {
            if reviveSourceMediaStalledCandidateIfFresh(
                previousSample: previousSample,
                sample: sample
            ) {
                await drive(isolation: isolation)
            }
            return
        }

        let progress = attempt.output.forwardingProgressSnapshot
        if progress.enqueueFailureCount > 0 {
            failAttempt(
                attempt,
                category: .runtimeEnqueueFailed
            )
        } else if !progress.queueRunning {
            failAttempt(
                attempt,
                category: .readinessFailed
            )
        } else {
            promoteDeferredReadinessIfPossible(
                attempt: attempt,
                progress: progress
            )
            attempt.lastInboundMediaSampleSequence = sample.sequence
            let hasExactContinuity = sample.watermark?.isContinuous(
                from: attempt.lastInboundMediaWatermark
            ) ?? false
            let didAdvance = hasExactContinuity
                && (sample.watermark?.advances(
                    from: attempt.lastInboundMediaWatermark
                ) ?? false)
            if hasExactContinuity, let watermark = sample.watermark {
                attempt.lastInboundMediaWatermark =
                    watermark.preservingMaximums(
                        from: attempt.lastInboundMediaWatermark
                    )
            }

            if didAdvance {
                attempt.inboundMediaAdvancementCount =
                    Self.nextNonzero(
                        attempt.inboundMediaAdvancementCount
                    )
                attempt.consecutiveStaleInboundMediaSamples = 0
                attempt.requiresFreshInboundMediaAdvance = false
                armMediaFreshnessWatchdog(
                    for: attempt,
                    isolation: isolation
                )
            } else if attempt.inboundMediaAdvancementCount > 0
                        || attempt.requiresFreshInboundMediaAdvance {
                attempt.consecutiveStaleInboundMediaSamples += 1
                if attempt.consecutiveStaleInboundMediaSamples
                    >= maximumStaleInboundMediaSamples {
                    failAttempt(
                        attempt,
                        category: .sourceMediaStalled
                    )
                }
            }

            if currentAttempt === attempt {
                updateForwardingPhase(for: attempt)
            }
        }

        if redriveRequested {
            await drive(isolation: isolation)
        }
    }

    @discardableResult
    func handleRuntimeFailure(
        isolation: isolated (any Actor)? = #isolation,
        from output: any WorldwideIPhoneMicrophoneOutput,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory
    ) async -> Bool {
        guard !isStopped,
              let attempt = currentAttempt,
              attempt.output === output else {
            return false
        }

        cancelMediaFreshnessWatchdog()
        currentAttempt = nil
        if track === attempt.track {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
        lastFailureCategory = category
        phase = Self.phase(for: category)
        redriveRequested = markRetryable(
            attempt.key,
            category: category
        )
        if redriveRequested {
            await drive(isolation: isolation)
        }
        return true
    }

    func shutdown(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped else { return }
        isStopped = true
        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false
        preserveFormatUnsafePhaseUntilPeerOrPairChanges = false
        transportAuthorized = false
        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        peer = nil
        phase = .stopped
        redriveRequested = false
    }

    func snapshot(
        isolation: isolated (any Actor)? = #isolation
    ) -> WorldwideIPhoneMicrophoneForwardingHostSnapshot {
        let progress = currentAttempt?
            .output
            .forwardingProgressSnapshot ?? .zero
        if let currentAttempt {
            promoteDeferredReadinessIfPossible(
                attempt: currentAttempt,
                progress: progress
            )
        }
        return WorldwideIPhoneMicrophoneForwardingHostSnapshot(
            policy: policy,
            phase: phase,
            monitorEpoch: activeMonitorEpoch,
            deviceGeneration:
                monitorSnapshot?.deviceGeneration ?? 0,
            deviceUID:
                monitorSnapshot?.defaultInputEndpoint?.deviceUID,
            sinkDeviceUID:
                monitorSnapshot?.hiddenMirrorSinkEndpoint?.deviceUID,
            deviceAvailable:
                monitorSnapshot?.isAvailable ?? false,
            currentKey: currentAttempt?.key,
            lastAttemptedKey: lastAttemptedKey,
            peerGeneration: peerGeneration,
            transportAuthorizationEpoch:
                transportAuthorizationEpoch,
            transportAuthorized: transportAuthorized,
            trackGeneration: trackGeneration,
            currentAttemptID: currentAttempt?.id,
            lastAttemptID: lastAttemptID,
            exactTrackAdmitted:
                currentAttempt?.exactTrackAdmitted ?? false,
            queueRunning: progress.queueRunning,
            progress: progress,
            inboundMediaSampleSequence:
                currentAttempt?.lastInboundMediaSampleSequence
                    ?? latestInboundMediaSample?.sequence ?? 0,
            inboundMediaAdvancementCount:
                currentAttempt?.inboundMediaAdvancementCount ?? 0,
            consecutiveStaleInboundMediaSamples:
                currentAttempt?.consecutiveStaleInboundMediaSamples
                    ?? 0,
            inboundMediaFresh:
                currentAttempt.map {
                    $0.sinkContinuingHealthProven
                        && sourceMediaIsFresh(for: $0)
                } ?? false,
            lastFailureCategory: lastFailureCategory
        )
    }

    private func drive(
        isolation: isolated (any Actor)?
    ) async {
        guard !isStopped else { return }
        if isDriving {
            redriveRequested = true
            return
        }

        isDriving = true
        defer { isDriving = false }

        while !isStopped {
            redriveRequested = false
            await driveOne(isolation: isolation)
            if redriveRequested || hasUnattemptedEligibleCandidate {
                continue
            }
            break
        }

        if currentAttempt == nil,
           currentCandidate() == nil {
            updateIneligiblePhase()
        }
    }

    private func driveOne(
        isolation: isolated (any Actor)?
    ) async {
        if let attempt = currentAttempt {
            guard candidateStillOwnsAttempt(attempt) else {
                finishSupersededAttempt(attempt)
                return
            }
            return
        }

        guard let candidate = currentCandidate() else {
            updateIneligiblePhase()
            return
        }
        guard candidateMayBeAttempted(candidate.key) else {
            return
        }

        if attemptHistory[candidate.key] != nil {
            do {
                try await retrySleep()
            } catch {
                guard candidateStillCurrent(candidate) else {
                    redriveRequested = true
                    return
                }
                markRetryExhausted(candidate.key)
                return
            }

            guard candidateStillCurrent(candidate) else {
                redriveRequested = true
                return
            }
        }

        rememberAttempted(candidate.key)
        let attemptID = makeAttemptID()
        lastAttemptID = attemptID

        guard let output = makeOutput(
            candidate.peer,
            candidate.sinkEndpoint
        ) else {
            failWithoutOutput(
                candidate: candidate,
                category: .outputUnavailable
            )
            return
        }

        let attempt = Attempt(
            id: attemptID,
            candidate: candidate,
            output: output,
            baselineInboundMediaSample:
                latestInboundMediaSample.map { sample in
                    sample.peerGeneration
                            == candidate.key.peerGeneration
                        && sample.trackGeneration
                            == candidate.key.trackGeneration
                        ? sample
                        : nil
                } ?? nil,
            // Every admitted receiver must prove one fresh RTP advance. Without this initial
            // watchdog, a newly negotiated track that never produces its first packet can leave
            // the virtual microphone indefinitely visible but silent in `awaitingFrames`.
            requiresFreshInboundMediaAdvance: true
        )
        currentAttempt = attempt
        phase = .starting

        do {
            try await startOutput(output)
        } catch {
            guard candidateStillOwnsAttempt(attempt) else {
                finishSupersededAttempt(attempt)
                return
            }
            if let outputError =
                    error as? BlackHoleMicrophoneOutputError,
               case .formatUnsafe(let rejection) =
                    outputError {
                failAttempt(
                    attempt,
                    category: .formatUnsafe,
                    allowRetry: false
                )
                await formatFailureHandler(
                    attempt.key,
                    rejection
                )
            } else if let outputError =
                        error as? BlackHoleMicrophoneOutputError,
                      case .sharedClockUnsafe(let rejection) =
                        outputError {
                failAttempt(
                    attempt,
                    category: .sharedClockUnsafe,
                    allowRetry: false
                )
                await sharedClockFailureHandler(
                    attempt.key,
                    rejection
                )
            } else {
                failAttempt(
                    attempt,
                    category: .startFailed,
                    allowRetry: !Task.isCancelled
                )
            }
            return
        }

        guard candidateStillOwnsAttempt(attempt) else {
            finishSupersededAttempt(attempt)
            return
        }
        // A replacement output reaches this point only after its queue has
        // committed the authoritative startup format and shared-clock proof.
        // The prior epoch rejection must not leak back into status if this
        // newly authorized route is later invalidated for another reason.
        preserveSharedClockUnsafePhaseUntilPeerOrPairChanges = false

        phase = .admittingTrack
        do {
            try await admit(attempt.peer, attempt.track)
        } catch {
            guard candidateStillOwnsAttempt(attempt) else {
                finishSupersededAttempt(attempt)
                return
            }
            failAttempt(attempt, category: .admissionFailed)
            return
        }

        guard candidateStillOwnsAttempt(attempt) else {
            finishSupersededAttempt(attempt)
            return
        }
        attempt.exactTrackAdmitted = true
        let admissionFloor = latestInboundMediaSample.flatMap { sample in
            sample.peerGeneration == attempt.key.peerGeneration
                && sample.trackGeneration == attempt.key.trackGeneration
                ? sample
                : nil
        }
        attempt.lastInboundMediaWatermark = admissionFloor?.watermark
        attempt.lastInboundMediaSampleSequence = admissionFloor?.sequence ?? 0
        attempt.inboundMediaAdvancementCount = 0
        attempt.consecutiveStaleInboundMediaSamples = 0
        phase = .checkingReadiness
        armMediaFreshnessWatchdog(
            for: attempt,
            isolation: isolation
        )
        await awaitReadiness(
            for: attempt,
            isolation: isolation
        )
    }

    private func awaitReadiness(
        for attempt: Attempt,
        isolation: isolated (any Actor)?
    ) async {
        var previousProgress:
            BlackHoleMicrophoneOutputProgressSnapshot?

        for sampleIndex in 0..<readinessSampleLimit {
            guard candidateStillOwnsAttempt(attempt) else {
                finishSupersededAttempt(attempt)
                return
            }

            if attempt.sinkContinuingHealthProven {
                updateForwardingPhase(for: attempt)
                return
            }

            let progress =
                attempt.output.forwardingProgressSnapshot
            if progress.enqueueFailureCount > 0 {
                failAttempt(
                    attempt,
                    category: .runtimeEnqueueFailed,
                    allowRetry: !Task.isCancelled
                )
                return
            }
            guard progress.queueRunning else {
                failAttempt(
                    attempt,
                    category: .readinessFailed,
                    allowRetry: !Task.isCancelled
                )
                return
            }

            if let previousProgress,
               progress.postStartCallbackCount
                > previousProgress.postStartCallbackCount,
               progress.successfulFrameCount
                == previousProgress.successfulFrameCount {
                // The queue callback is alive but still zero-filling. Keep
                // this exact attempt admitted while the source starts; this
                // state must not consume its retry budget.
                attempt.deferredReadyProgress = nil
                phase = .awaitingFrames
                return
            }
            previousProgress = progress

            if WorldwideIPhoneMicrophoneForwardingProgressEvaluator
                .isReady(progress) {
                if let previous = attempt.deferredReadyProgress,
                   WorldwideIPhoneMicrophoneForwardingProgressEvaluator
                    .provesContinuingHealth(
                        previous: previous,
                        current: progress
                    ) {
                    guard candidateStillOwnsAttempt(attempt) else {
                        finishSupersededAttempt(attempt)
                        return
                    }
                    attempt.sinkContinuingHealthProven = true
                    attempt.deferredReadyProgress = progress
                    updateForwardingPhase(for: attempt)
                    return
                }

                attempt.deferredReadyProgress = progress
                phase = .forwardingReady
            }

            guard sampleIndex + 1 < readinessSampleLimit else {
                break
            }

            do {
                try await readinessSleep()
            } catch {
                guard candidateStillOwnsAttempt(attempt) else {
                    finishSupersededAttempt(attempt)
                    return
                }
                failAttempt(
                    attempt,
                    category: .readinessFailed,
                    allowRetry: !Task.isCancelled
                )
                return
            }
        }

        guard candidateStillOwnsAttempt(attempt) else {
            finishSupersededAttempt(attempt)
            return
        }
        failAttempt(
            attempt,
            category: .readinessFailed,
            allowRetry: !Task.isCancelled
        )
    }

    private var hasUnattemptedEligibleCandidate: Bool {
        guard currentAttempt == nil,
              let candidate = currentCandidate() else {
            return false
        }
        return candidateMayBeAttempted(candidate.key)
    }

    private func currentCandidate() -> Candidate? {
        guard !isStopped,
              policy == .enabled,
              !monitoringFailed,
              let activeMonitorEpoch,
              let monitorSnapshot,
              monitorSnapshot.monitorEpoch == activeMonitorEpoch,
              monitorSnapshot.isAvailable,
              monitorSnapshot.deviceGeneration > 0,
              let defaultInputDeviceUID = monitorSnapshot
                .defaultInputEndpoint?.deviceUID,
              !defaultInputDeviceUID.isEmpty,
              let defaultInputEndpoint = monitorSnapshot
                .defaultInputEndpoint,
              defaultInputEndpoint.deviceUID
                == defaultInputDeviceUID,
              let sinkEndpoint = monitorSnapshot
                .hiddenMirrorSinkEndpoint,
              !sinkEndpoint.deviceUID.isEmpty,
              sinkEndpoint.deviceUID != defaultInputDeviceUID,
              sinkEndpoint.deviceID
                != defaultInputEndpoint.deviceID,
              let peer,
              peerGeneration > 0,
              transportAuthorized,
              transportAuthorizationEpoch > 0,
              let track,
              trackGeneration > 0 else {
            return nil
        }

        return Candidate(
            key: WorldwideIPhoneMicrophoneForwardingKey(
                monitorEpoch: activeMonitorEpoch,
                deviceGeneration:
                    monitorSnapshot.deviceGeneration,
                peerGeneration: peerGeneration,
                transportAuthorizationEpoch:
                    transportAuthorizationEpoch,
                trackGeneration: trackGeneration
            ),
            peer: peer,
            track: track,
            sinkEndpoint: sinkEndpoint
        )
    }

    private func candidateStillOwnsAttempt(
        _ attempt: Attempt
    ) -> Bool {
        guard currentAttempt === attempt,
              let candidate = currentCandidate(),
              candidate.key == attempt.key,
              candidate.peer === attempt.peer,
              candidate.track === attempt.track,
              candidate.sinkEndpoint == attempt.sinkEndpoint else {
            return false
        }
        return true
    }

    private func candidateStillCurrent(
        _ candidate: Candidate
    ) -> Bool {
        guard let current = currentCandidate(),
              current.key == candidate.key,
              current.peer === candidate.peer,
              current.track === candidate.track,
              current.sinkEndpoint == candidate.sinkEndpoint else {
            return false
        }
        return true
    }

    private func promoteDeferredReadinessIfPossible(
        attempt: Attempt,
        progress: BlackHoleMicrophoneOutputProgressSnapshot
    ) {
        guard currentAttempt === attempt,
              attempt.exactTrackAdmitted else {
            return
        }
        if attempt.sinkContinuingHealthProven {
            updateForwardingPhase(for: attempt)
            return
        }
        guard phase == .checkingReadiness
                || phase == .awaitingFrames
                || phase == .forwardingReady else {
            return
        }
        guard WorldwideIPhoneMicrophoneForwardingProgressEvaluator
                .isReady(progress) else {
            attempt.deferredReadyProgress = nil
            phase = .awaitingFrames
            return
        }

        if let previous = attempt.deferredReadyProgress,
           WorldwideIPhoneMicrophoneForwardingProgressEvaluator
            .provesContinuingHealth(
                previous: previous,
                current: progress
            ) {
            attempt.sinkContinuingHealthProven = true
            attempt.deferredReadyProgress = progress
            updateForwardingPhase(for: attempt)
            return
        }

        attempt.deferredReadyProgress = progress
        phase = .forwardingReady
    }

    private func updateForwardingPhase(
        for attempt: Attempt
    ) {
        guard currentAttempt === attempt,
              attempt.exactTrackAdmitted else {
            return
        }
        if attempt.sinkContinuingHealthProven,
           sourceMediaIsFresh(for: attempt) {
            phase = .forwardingHealthy
        } else if attempt.sinkContinuingHealthProven {
            phase = .awaitingFrames
        } else if attempt.deferredReadyProgress != nil {
            phase = .forwardingReady
        } else {
            phase = .awaitingFrames
        }
    }

    private func sourceMediaIsFresh(
        for attempt: Attempt
    ) -> Bool {
        guard let deadline =
                attempt.mediaFreshnessDeadlineNanoseconds else {
            return false
        }
        return attempt.inboundMediaAdvancementCount > 0
            && attempt.consecutiveStaleInboundMediaSamples
                < maximumStaleInboundMediaSamples
            && mediaFreshnessNow() < deadline
    }

    private func armMediaFreshnessWatchdog(
        for attempt: Attempt,
        isolation: isolated (any Actor)?
    ) {
        precondition(
            isolation != nil,
            "The forwarding driver watchdog requires actor ownership."
        )
        guard candidateStillOwnsAttempt(attempt),
              attempt.exactTrackAdmitted else {
            return
        }

        cancelMediaFreshnessWatchdog()
        attempt.mediaFreshnessWatchdogGeneration =
            Self.nextNonzero(
                attempt.mediaFreshnessWatchdogGeneration
            )
        let deadline = Self.addingClamped(
            mediaFreshnessNow(),
            mediaFreshnessTimeoutNanoseconds
        )
        attempt.mediaFreshnessDeadlineNanoseconds = deadline

        let attemptID = attempt.id
        let key = attempt.key
        let peerIdentity = ObjectIdentifier(attempt.peer)
        let trackIdentity = ObjectIdentifier(attempt.track)
        let outputIdentity = ObjectIdentifier(attempt.output)
        let watchdogGeneration =
            attempt.mediaFreshnessWatchdogGeneration
        let deadlineSleep = mediaFreshnessDeadlineSleep
        let now = mediaFreshnessNow

        mediaFreshnessWatchdogTask = Task { [weak self] in
            do {
                while !Task.isCancelled, now() < deadline {
                    try await deadlineSleep(deadline)
                }
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            await self.mediaFreshnessWatchdogDidReachDeadline(
                isolation: isolation,
                attemptID: attemptID,
                key: key,
                peerIdentity: peerIdentity,
                trackIdentity: trackIdentity,
                outputIdentity: outputIdentity,
                watchdogGeneration: watchdogGeneration,
                deadlineNanoseconds: deadline
            )
        }
    }

    private func mediaFreshnessWatchdogDidReachDeadline(
        isolation: isolated (any Actor)?,
        attemptID: UUID,
        key: WorldwideIPhoneMicrophoneForwardingKey,
        peerIdentity: ObjectIdentifier,
        trackIdentity: ObjectIdentifier,
        outputIdentity: ObjectIdentifier,
        watchdogGeneration: UInt64,
        deadlineNanoseconds: UInt64
    ) async {
        guard !isStopped,
              mediaFreshnessNow() >= deadlineNanoseconds,
              let attempt = currentAttempt,
              candidateStillOwnsAttempt(attempt),
              attempt.exactTrackAdmitted,
              attempt.id == attemptID,
              attempt.key == key,
              ObjectIdentifier(attempt.peer) == peerIdentity,
              ObjectIdentifier(attempt.track) == trackIdentity,
              ObjectIdentifier(attempt.output) == outputIdentity,
              attempt.mediaFreshnessWatchdogGeneration
                == watchdogGeneration,
              attempt.mediaFreshnessDeadlineNanoseconds
                == deadlineNanoseconds else {
            return
        }

        // Clear the task before failing so the deadline task does not cancel
        // itself and poison the bounded retry sleep that follows.
        mediaFreshnessWatchdogTask = nil
        attempt.mediaFreshnessDeadlineNanoseconds = nil
        failAttempt(attempt, category: .sourceMediaStalled)
        if redriveRequested {
            await drive(isolation: isolation)
        }
    }

    private func cancelMediaFreshnessWatchdog() {
        mediaFreshnessWatchdogTask?.cancel()
        mediaFreshnessWatchdogTask = nil
    }

    private func invalidateCurrentAttempt() {
        guard let attempt = currentAttempt else { return }
        cancelMediaFreshnessWatchdog()
        currentAttempt = nil
        if track === attempt.track {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
    }

    private func finishSupersededAttempt(
        _ attempt: Attempt
    ) {
        if currentAttempt === attempt {
            cancelMediaFreshnessWatchdog()
            currentAttempt = nil
        }

        let replacementOwnsSameTrack =
            currentAttempt.map {
                $0.track === attempt.track
            } ?? false
        if !replacementOwnsSameTrack {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
        redriveRequested = true
    }

    private func failAttempt(
        _ attempt: Attempt,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory,
        allowRetry: Bool = true
    ) {
        guard currentAttempt === attempt else {
            finishSupersededAttempt(attempt)
            return
        }

        cancelMediaFreshnessWatchdog()
        currentAttempt = nil
        if track === attempt.track {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
        lastFailureCategory = category
        phase = Self.phase(for: category)
        redriveRequested = allowRetry
            && markRetryable(
                attempt.key,
                category: category
            )
    }

    private func failWithoutOutput(
        candidate: Candidate,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory
    ) {
        guard let current = currentCandidate(),
              current.key == candidate.key,
              current.peer === candidate.peer,
              current.track === candidate.track else {
            redriveRequested = true
            return
        }

        disableTrack(candidate.track)
        lastFailureCategory = category
        phase = Self.phase(for: category)
        redriveRequested = markRetryable(
            candidate.key,
            category: category
        )
    }

    private func rememberAttempted(
        _ key: WorldwideIPhoneMicrophoneForwardingKey
    ) {
        if var history = attemptHistory[key] {
            history.count += 1
            history.mayRetry = false
            attemptHistory[key] = history
        } else {
            attemptHistory[key] = AttemptHistory(
                count: 1,
                mayRetry: false
            )
            attemptedKeyOrder.append(key)
        }

        let maximumRetainedKeys = 256
        while attemptedKeyOrder.count > maximumRetainedKeys {
            let removed = attemptedKeyOrder.removeFirst()
            attemptHistory.removeValue(forKey: removed)
        }
        lastAttemptedKey = key
    }

    private func candidateMayBeAttempted(
        _ key: WorldwideIPhoneMicrophoneForwardingKey
    ) -> Bool {
        guard let history = attemptHistory[key] else {
            return true
        }
        return history.mayRetry
            && history.count < maximumAttemptCountPerKey
    }

    @discardableResult
    private func markRetryable(
        _ key: WorldwideIPhoneMicrophoneForwardingKey,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory
    ) -> Bool {
        guard Self.isRetryable(category),
              var history = attemptHistory[key],
              history.count < maximumAttemptCountPerKey else {
            return false
        }
        history.mayRetry = true
        attemptHistory[key] = history
        return true
    }

    private func markRetryExhausted(
        _ key: WorldwideIPhoneMicrophoneForwardingKey
    ) {
        guard var history = attemptHistory[key] else {
            return
        }
        history.mayRetry = false
        attemptHistory[key] = history
        redriveRequested = false
    }

    private func reviveSourceMediaStalledCandidateIfFresh(
        previousSample: InboundMediaSample?,
        sample: InboundMediaSample
    ) -> Bool {
        guard currentAttempt == nil,
              lastFailureCategory == .sourceMediaStalled,
              let candidate = currentCandidate(),
              candidate.key.peerGeneration
                == sample.peerGeneration,
              candidate.key.trackGeneration
                == sample.trackGeneration,
              let previousSample,
              previousSample.peerGeneration
                == sample.peerGeneration,
              previousSample.trackGeneration
                == sample.trackGeneration,
              sample.sequence > previousSample.sequence,
              sample.watermark?.isContinuous(
                from: previousSample.watermark
              ) == true,
              sample.watermark?.advances(
                from: previousSample.watermark
              ) == true else {
            return false
        }

        attemptHistory.removeValue(forKey: candidate.key)
        attemptedKeyOrder.removeAll { $0 == candidate.key }
        redriveRequested = true
        return true
    }

    private func disableCurrentTrack() {
        if let track {
            disableTrack(track)
        }
    }

    private func updateIneligiblePhase() {
        guard currentAttempt == nil else { return }
        if isStopped {
            phase = .stopped
            return
        }
        if policy == .suppressedForLANCoexistence {
            phase = .suppressedForLANCoexistence
            return
        }
        if monitoringFailed {
            phase = .monitoringFailed
            return
        }
        if preserveSharedClockUnsafePhaseUntilPeerOrPairChanges {
            phase = .sharedClockUnsafe
            return
        }
        if preserveFormatUnsafePhaseUntilPeerOrPairChanges {
            phase = .formatUnsafe
            return
        }
        guard activeMonitorEpoch != nil,
              let monitorSnapshot else {
            phase = .waitingForMonitor
            return
        }
        guard monitorSnapshot.isAvailable,
              monitorSnapshot.defaultInputEndpoint != nil,
              monitorSnapshot.hiddenMirrorSinkEndpoint != nil else {
            phase = .waitingForDevice
            return
        }
        guard peer != nil else {
            phase = .waitingForPeer
            return
        }
        guard transportAuthorized else {
            phase = .waitingForTransport
            return
        }
        guard track != nil else {
            phase = .waitingForTrack
            return
        }

        if let candidate = currentCandidate(),
           attemptHistory[candidate.key] != nil,
           !candidateMayBeAttempted(candidate.key) {
            // Preserve the terminal result for this already-attempted key.
            return
        }
        phase = .waitingForTrack
    }

    private static func phase(
        for category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory
    ) -> WorldwideIPhoneMicrophoneForwardingPhase {
        switch category {
        case .monitoringFailed:
            .monitoringFailed
        case .outputUnavailable:
            .outputUnavailable
        case .startFailed:
            .startFailed
        case .admissionFailed:
            .admissionFailed
        case .readinessFailed:
            .readinessFailed
        case .sourceMediaStalled:
            .sourceMediaStalled
        case .formatUnsafe:
            .formatUnsafe
        case .sharedClockUnsafe:
            .sharedClockUnsafe
        case .runtimeEnqueueFailed, .runtimeProgressStalled:
            .runtimeFailed
        }
    }

    private static func isRetryable(
        _ category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory
    ) -> Bool {
        switch category {
        case .outputUnavailable, .startFailed,
             .readinessFailed, .sourceMediaStalled,
             .runtimeEnqueueFailed, .runtimeProgressStalled:
            true
        case .monitoringFailed, .admissionFailed,
             .formatUnsafe:
            false
        case .sharedClockUnsafe:
            false
        }
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private static func addingClamped(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

protocol WorldwideBlackHoleDefaultInputLeasing:
    AnyObject,
    Sendable
{
    func acquisitionResult(
        generation: UInt64,
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult
    func authorizationProof(
        generation: UInt64,
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseAuthorization?
    func release(
        generation: UInt64
    ) -> BlackHoleDefaultInputLeaseReleaseResult
    func parkForClockEpochRecovery(
        generation: UInt64,
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseParkingResult
    func clockEpochParkingProofIsCurrent(
        _ proof: BlackHoleDefaultInputLeaseParkingProof
    ) -> Bool
    func reacquisitionResult(
        parkingProof: BlackHoleDefaultInputLeaseParkingProof,
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult
    func shutdown()
        -> BlackHoleDefaultInputLeaseReleaseResult
}

extension BlackHoleDefaultInputLease:
    WorldwideBlackHoleDefaultInputLeasing
{}

struct WorldwideBlackHoleDefaultInputKey:
    Equatable,
    Sendable
{
    let monitorEpoch: UUID
    let deviceGeneration: UInt64
    let peerGeneration: UInt64
    let connectionGeneration: UInt64
    let leaseGeneration: UInt64
    let deviceEndpoint: BlackHoleDeviceEndpointIdentity
    let inputAuthorization:
        BlackHoleDefaultInputLeaseAuthorization

    var deviceUID: String {
        deviceEndpoint.deviceUID
    }
}

enum WorldwideBlackHoleDefaultInputOutcome:
    Equatable,
    Sendable
{
    case noChange
    case waitingForMonitor
    case waitingForDevice
    case selected(WorldwideBlackHoleDefaultInputKey)
    case released
    case degraded
    case suppressed
}

enum WorldwideBlackHoleClockEpochParkingOutcome:
    Equatable,
    Sendable
{
    case parked(BlackHoleDefaultInputLeaseParkingProof)
    case degraded
}

enum WorldwideBlackHoleAudioRoutingCleanupResult:
    Equatable,
    Sendable
{
    case cleaned
    case degraded
}

/// Runs default-input and device-list cleanup as one bounded lifecycle policy.
///
/// Every episode drives both owners. A completed half remains safe to call
/// idempotently while the other half is redriven with its retained exact
/// Core Audio identity.
enum WorldwideBlackHoleAudioRoutingCleanupPolicy {
    static func run(
        maximumEpisodeCount: Int,
        shutdownDefaultInput:
            () -> WorldwideBlackHoleDefaultInputOutcome,
        stopDeviceMonitor:
            () -> BlackHoleDeviceAvailabilityMonitorStopResult
    ) -> WorldwideBlackHoleAudioRoutingCleanupResult {
        let boundedEpisodeCount = max(
            1,
            maximumEpisodeCount
        )

        for _ in 0..<boundedEpisodeCount {
            let defaultInputOutcome =
                shutdownDefaultInput()
            let monitorOutcome =
                stopDeviceMonitor()

            if defaultInputOutcome != .degraded,
               monitorOutcome == .stopped {
                return .cleaned
            }
        }

        return .degraded
    }
}

protocol WorldwideBlackHoleAudioRoutingCleanupRetaining:
    AnyObject,
    Sendable
{
    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    )
    func remove(id: UUID)

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int

    var retainedJobCount: Int { get }
}

/// One shared lifecycle fence between retained exact Core Audio cleanup and
/// installation of any replacement monitor/default-input ownership.
enum WorldwideBlackHoleAudioRoutingStartupGate {
    static func redriveAndPermitNewOwnership(
        retainer:
            any WorldwideBlackHoleAudioRoutingCleanupRetaining,
        maximumAttemptCount: Int = 1,
        deferredDefaultInputCleanup:
            @Sendable (Int) -> Bool = {
                maximumAttemptCount in
                BlackHoleDefaultInputLease
                    .redriveRetainedDeferredCleanup(
                        maximumAttemptCount:
                            maximumAttemptCount
                    )
            }
    ) -> Bool {
        let defaultInputCleanupCompleted =
            deferredDefaultInputCleanup(
                maximumAttemptCount
            )
        let serviceCleanupCompleted =
            retainer.redriveRetained(
                maximumAttemptCount:
                    maximumAttemptCount
            ) == 0
        return defaultInputCleanupCompleted
            && serviceCleanupCompleted
    }
}

/// Retains exact degraded Core Audio cleanup ownership after its originating
/// service has stopped.
///
/// Each redrive call has one global attempt budget shared across all retained
/// jobs. A failed job moves to the back of the queue and remains retained for a
/// later explicit lifecycle redrive; there is no timer loop or unbounded retry.
final class WorldwideBlackHoleAudioRoutingCleanupRetainer:
    WorldwideBlackHoleAudioRoutingCleanupRetaining,
    @unchecked Sendable
{
    private struct Job {
        let id: UUID
        let attempt: @Sendable () -> Bool
    }

    static let shared =
        WorldwideBlackHoleAudioRoutingCleanupRetainer()

    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private var jobOrder: [UUID] = []

    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    ) {
        withLock {
            let isNew = jobs[id] == nil
            jobs[id] = Job(
                id: id,
                attempt: attempt
            )
            if isNew {
                jobOrder.append(id)
            }
        }
    }

    func remove(id: UUID) {
        withLock {
            jobs.removeValue(forKey: id)
            jobOrder.removeAll {
                $0 == id
            }
        }
    }

    /// Performs at most `maximumAttemptCount` total cleanup episodes, not that
    /// many episodes per retained owner.
    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int {
        let boundedAttemptCount = max(
            0,
            maximumAttemptCount
        )

        for _ in 0..<boundedAttemptCount {
            let job: Job? = withLock {
                while let id = jobOrder.first {
                    jobOrder.removeFirst()
                    if let job = jobs[id] {
                        return job
                    }
                }
                return nil
            }
            guard let job else {
                break
            }

            let completed = job.attempt()
            withLock {
                guard jobs[job.id] != nil else {
                    return
                }
                if completed {
                    jobs.removeValue(
                        forKey: job.id
                    )
                } else {
                    jobOrder.append(job.id)
                }
            }
        }

        return retainedJobCount
    }

    var retainedJobCount: Int {
        withLock {
            jobs.count
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

/// Connection-level default-input ownership, deliberately independent of remote
/// track arrival, decoded PCM, and forwarding readiness.
final class WorldwideBlackHoleDefaultInputCoordinator {
    private struct CandidateIdentity: Equatable {
        let monitorEpoch: UUID
        let deviceGeneration: UInt64
        let peerGeneration: UInt64
        let connectionGeneration: UInt64
        let deviceEndpoint: BlackHoleDeviceEndpointIdentity
    }

    private struct LeaseKey: Equatable {
        let monitorEpoch: UUID
        let deviceGeneration: UInt64
        let peerGeneration: UInt64
        let connectionGeneration: UInt64
        let leaseGeneration: UInt64
        let deviceEndpoint: BlackHoleDeviceEndpointIdentity

        init(
            monitorEpoch: UUID,
            deviceGeneration: UInt64,
            peerGeneration: UInt64,
            connectionGeneration: UInt64,
            leaseGeneration: UInt64,
            deviceEndpoint: BlackHoleDeviceEndpointIdentity
        ) {
            self.monitorEpoch = monitorEpoch
            self.deviceGeneration = deviceGeneration
            self.peerGeneration = peerGeneration
            self.connectionGeneration = connectionGeneration
            self.leaseGeneration = leaseGeneration
            self.deviceEndpoint = deviceEndpoint
        }

        init(_ key: WorldwideBlackHoleDefaultInputKey) {
            self.init(
                monitorEpoch: key.monitorEpoch,
                deviceGeneration: key.deviceGeneration,
                peerGeneration: key.peerGeneration,
                connectionGeneration: key.connectionGeneration,
                leaseGeneration: key.leaseGeneration,
                deviceEndpoint: key.deviceEndpoint
            )
        }

        func authorized(
            by authorization:
                BlackHoleDefaultInputLeaseAuthorization
        ) -> WorldwideBlackHoleDefaultInputKey {
            WorldwideBlackHoleDefaultInputKey(
                monitorEpoch: monitorEpoch,
                deviceGeneration: deviceGeneration,
                peerGeneration: peerGeneration,
                connectionGeneration: connectionGeneration,
                leaseGeneration: leaseGeneration,
                deviceEndpoint: deviceEndpoint,
                inputAuthorization: authorization
            )
        }
    }

    private enum ReleaseDisposition {
        case noChange
        case released
        case retryableFailure
        case externallySuperseded
    }

    private let policy:
        WorldwideIPhoneMicrophoneForwardingPolicy
    private let lease:
        any WorldwideBlackHoleDefaultInputLeasing
    private let maximumAcquisitionAttemptCount: Int
    private let maximumReleaseAttemptCount: Int
    private let maximumShutdownAttemptCount: Int

    private var activeMonitorEpoch: UUID?
    private var monitorSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var healthyPeerGeneration: UInt64?
    private var highestPeerGenerationSeen: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var nextLeaseGeneration: UInt64 = 0
    private var activeKey: WorldwideBlackHoleDefaultInputKey?
    private var pendingKey: LeaseKey?
    private var releaseIsPending = false
    private var clockEpochParkingProof:
        BlackHoleDefaultInputLeaseParkingProof?
    private var terminalConnectionGeneration: UInt64?
    private var externallySupersededPeerGeneration: UInt64?
    private var lastAttemptedIdentity: CandidateIdentity?
    private var acquisitionAttemptCount = 0
    private var isStopped = false
    private var shutdownCleanupWasPending = false

    init(
        policy:
            WorldwideIPhoneMicrophoneForwardingPolicy,
        lease:
            any WorldwideBlackHoleDefaultInputLeasing,
        maximumAcquisitionAttemptCount: Int = 3,
        maximumReleaseAttemptCount: Int = 1,
        maximumShutdownAttemptCount: Int = 1
    ) {
        self.policy = policy
        self.lease = lease
        self.maximumAcquisitionAttemptCount = max(
            1,
            maximumAcquisitionAttemptCount
        )
        self.maximumReleaseAttemptCount = max(
            1,
            maximumReleaseAttemptCount
        )
        self.maximumShutdownAttemptCount = max(
            1,
            maximumShutdownAttemptCount
        )
    }

    func beginMonitoring(
        epoch: UUID
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        guard activeMonitorEpoch != epoch else {
            return .noChange
        }

        let release = releaseActiveBounded()
        activeMonitorEpoch = epoch
        monitorSnapshot = nil
        resetAcquisitionAttempts()
        return outcome(
            for: release,
            whenNoChange: .waitingForMonitor
        )
    }

    func monitoringDidFail()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        _ = releaseActiveBounded()
        activeMonitorEpoch = nil
        monitorSnapshot = nil
        resetAcquisitionAttempts()
        return .degraded
    }

    func deviceRevalidationDidFail()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        _ = releaseActiveBounded()
        monitorSnapshot = nil
        resetAcquisitionAttempts()
        return .degraded
    }

    func updateDeviceSnapshot(
        _ snapshot:
            BlackHoleDeviceAvailabilitySnapshot
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        guard snapshot.monitorEpoch
                == activeMonitorEpoch else {
            return .noChange
        }
        if let monitorSnapshot {
            guard snapshot.deviceGeneration
                    > monitorSnapshot.deviceGeneration else {
                return .noChange
            }
        }

        monitorSnapshot = snapshot
        if !snapshot.isAvailable
            || snapshot.defaultInputEndpoint == nil
            || snapshot.hiddenMirrorSinkEndpoint == nil {
            resetAcquisitionAttempts()
            return outcome(
                for: releaseActiveBounded(),
                whenNoChange: .waitingForDevice
            )
        }
        return drive()
    }

    func transportDidBecomeHealthy(
        peerGeneration: UInt64
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped, peerGeneration > 0 else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        guard clockEpochParkingProof == nil else {
            return .degraded
        }
        guard peerGeneration
                >= highestPeerGenerationSeen else {
            return .noChange
        }
        let isStrictlyNewerPeer =
            peerGeneration > highestPeerGenerationSeen
        if isStrictlyNewerPeer {
            highestPeerGenerationSeen = peerGeneration
        }

        if externallySupersededPeerGeneration
                == peerGeneration {
            if releaseIsPending {
                _ = releaseActiveBounded()
            }
            return .degraded
        }

        if healthyPeerGeneration == peerGeneration {
            return drive()
        }

        let release = releaseActiveBounded()
        healthyPeerGeneration = peerGeneration
        connectionGeneration = Self.nextNonzero(
            connectionGeneration
        )
        terminalConnectionGeneration = nil
        resetAcquisitionAttempts()
        if isStrictlyNewerPeer {
            // A genuinely newer authenticated peer is the only runtime event
            // allowed to clear a prior external-selector terminal fence.
            externallySupersededPeerGeneration = nil
        }
        if release == .retryableFailure {
            return .degraded
        }
        return drive()
    }

    func transportDidBecomeUnhealthy(
        peerGeneration: UInt64
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        let ownsPeer =
            healthyPeerGeneration == peerGeneration
                || activeKey?.peerGeneration == peerGeneration
                || pendingKey?.peerGeneration == peerGeneration
        guard ownsPeer else {
            return .noChange
        }
        if healthyPeerGeneration == peerGeneration {
            healthyPeerGeneration = nil
        }
        resetAcquisitionAttempts()
        let release = releaseActiveBounded()
        let releaseOutcome = outcome(
            for: release,
            whenNoChange: .noChange
        )
        switch release {
        case .retryableFailure:
            return releaseOutcome
        case .noChange, .released,
             .externallySuperseded:
            break
        }

        guard healthyPeerGeneration != nil else {
            return releaseOutcome
        }
        let replacementOutcome = drive()
        if case .noChange = replacementOutcome {
            return releaseOutcome
        }
        return replacementOutcome
    }

    func parkForSharedClockEpochRecovery(
        peerGeneration: UInt64
    ) -> WorldwideBlackHoleClockEpochParkingOutcome {
        guard !isStopped,
              policy == .enabled,
              healthyPeerGeneration == peerGeneration,
              let activeKey,
              activeKey.peerGeneration == peerGeneration,
              pendingKey == nil,
              !releaseIsPending,
              clockEpochParkingProof == nil else {
            return .degraded
        }

        healthyPeerGeneration = nil
        resetAcquisitionAttempts()
        switch lease.parkForClockEpochRecovery(
            generation: activeKey.leaseGeneration,
            targetEndpoint: activeKey.deviceEndpoint
        ) {
        case .parked(let proof)
            where proof.leaseGeneration
                == activeKey.leaseGeneration
                && proof.targetEndpoint
                    == activeKey.deviceEndpoint:
            self.activeKey = LeaseKey(activeKey).authorized(
                by: BlackHoleDefaultInputLeaseAuthorization(
                    leaseGeneration: proof.leaseGeneration,
                    listenerRegistrationID:
                        proof.listenerRegistrationID,
                    acceptedListenerSequence:
                        proof.acceptedListenerSequence,
                    targetEndpoint: proof.targetEndpoint
                )
            )
            clockEpochParkingProof = proof
            return .parked(proof)

        case .parked, .retryableFailure, .terminalFailure:
            _ = releaseActiveBounded()
            return .degraded
        }
    }

    func sharedClockParkingProofIsCurrent(
        _ proof: BlackHoleDefaultInputLeaseParkingProof,
        peerGeneration: UInt64,
        snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) -> Bool {
        guard clockEpochParkingProof == proof,
              healthyPeerGeneration == nil,
              let activeKey,
              activeKey.leaseGeneration == proof.leaseGeneration,
              activeKey.peerGeneration == peerGeneration,
              activeKey.monitorEpoch == snapshot.monitorEpoch,
              activeKey.deviceGeneration
                == snapshot.deviceGeneration,
              activeKey.deviceEndpoint
                == snapshot.defaultInputEndpoint,
              proof.targetEndpoint == activeKey.deviceEndpoint else {
            return false
        }
        guard lease.clockEpochParkingProofIsCurrent(proof) else {
            _ = releaseActiveBounded()
            return false
        }
        return true
    }

    func transportDidBecomeHealthyAfterSharedClockRecovery(
        peerGeneration: UInt64,
        parkingProof: BlackHoleDefaultInputLeaseParkingProof
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped,
              policy == .enabled,
              healthyPeerGeneration == nil,
              clockEpochParkingProof == parkingProof,
              let snapshot = monitorSnapshot,
              snapshot.isAvailable,
              let activeKey,
              activeKey.peerGeneration == peerGeneration,
              activeKey.monitorEpoch == snapshot.monitorEpoch,
              activeKey.deviceGeneration
                == snapshot.deviceGeneration,
              activeKey.deviceEndpoint
                == snapshot.defaultInputEndpoint,
              parkingProof.targetEndpoint
                == activeKey.deviceEndpoint,
              !releaseIsPending else {
            return .degraded
        }
        guard lease.clockEpochParkingProofIsCurrent(
            parkingProof
        ) else {
            _ = releaseActiveBounded()
            return .degraded
        }

        switch lease.reacquisitionResult(
            parkingProof: parkingProof,
            targetEndpoint: activeKey.deviceEndpoint
        ) {
        case .acquired:
            guard let authorization =
                    authorizationProof(
                        for: LeaseKey(activeKey)
                    ) else {
                _ = releaseActiveBounded()
                return .degraded
            }
            let refreshedKey = LeaseKey(activeKey).authorized(
                by: authorization
            )
            self.activeKey = refreshedKey
            clockEpochParkingProof = nil
            healthyPeerGeneration = peerGeneration
            return .selected(refreshedKey)

        case .retryableFailure, .terminalFailure:
            _ = releaseActiveBounded()
            return .degraded
        }
    }

    /// Consumes a raw exact-listener event after the realtime writer gate has
    /// already been closed. Only the event incorporated by the current proof is
    /// stale. Every other event terminalizes this connection generation and
    /// releases without restoring over the external selector choice.
    func defaultInputDidBecomeUncertain(
        _ event: BlackHoleDefaultInputLeaseUncertaintyEvent
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        guard let activeKey else {
            return .noChange
        }
        let authorization =
            activeKey.inputAuthorization
        guard event.leaseGeneration
                == activeKey.leaseGeneration,
              event.listenerRegistrationID
                == authorization.listenerRegistrationID else {
            // A callback retained by an older registration cannot poison the
            // current peer or replacement lease.
            return .noChange
        }
        if authorization.incorporates(event) {
            return .noChange
        }

        recordExternalSupersession(
            peerGeneration:
                activeKey.peerGeneration
        )
        terminalConnectionGeneration =
            activeKey.connectionGeneration
        resetAcquisitionAttempts()
        _ = releaseActiveBounded()
        return .degraded
    }

    func invalidateCurrentConnection()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        healthyPeerGeneration = nil
        resetAcquisitionAttempts()
        return outcome(
            for: releaseActiveBounded(),
            whenNoChange: .noChange
        )
    }

    func shutdown()
        -> WorldwideBlackHoleDefaultInputOutcome {
        if !isStopped {
            isStopped = true
            healthyPeerGeneration = nil
            resetAcquisitionAttempts()
        }

        var completedCleanup =
            shutdownCleanupWasPending
        var attemptCount = 0

        while attemptCount
                < maximumShutdownAttemptCount {
            attemptCount += 1

            let release = releaseActiveBounded()
            switch release {
            case .retryableFailure:
                shutdownCleanupWasPending = true
                continue

            case .released,
                 .externallySuperseded:
                completedCleanup = true

            case .noChange:
                break
            }

            switch lease.shutdown() {
            case .released,
                 .externallySuperseded:
                shutdownCleanupWasPending = false
                return completedCleanup
                    ? .released
                    : .noChange

            case .retryableFailure:
                shutdownCleanupWasPending = true
            }
        }

        return .degraded
    }

    private func drive()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard clockEpochParkingProof == nil else {
            return .degraded
        }
        guard let activeMonitorEpoch,
              let monitorSnapshot else {
            return .waitingForMonitor
        }
        guard monitorSnapshot.isAvailable,
              let deviceEndpoint =
                monitorSnapshot.defaultInputEndpoint,
              !deviceEndpoint.deviceUID.isEmpty,
              monitorSnapshot.defaultInputEndpoint?.deviceUID
                == deviceEndpoint.deviceUID,
              monitorSnapshot.hiddenMirrorSinkEndpoint != nil else {
            return .waitingForDevice
        }
        guard let healthyPeerGeneration else {
            return .noChange
        }
        if externallySupersededPeerGeneration
                == healthyPeerGeneration {
            return .degraded
        }
        if terminalConnectionGeneration
                == connectionGeneration,
           activeKey == nil,
           pendingKey == nil {
            return .degraded
        }

        let identity = CandidateIdentity(
            monitorEpoch: activeMonitorEpoch,
            deviceGeneration:
                monitorSnapshot.deviceGeneration,
            peerGeneration: healthyPeerGeneration,
            connectionGeneration:
                connectionGeneration,
            deviceEndpoint: deviceEndpoint
        )
        let currentLeaseKey =
            activeKey.map(LeaseKey.init) ?? pendingKey
        let activeKeyMatchesIdentity =
            currentLeaseKey.map {
                $0.monitorEpoch == identity.monitorEpoch
                    && $0.deviceGeneration
                        == identity.deviceGeneration
                    && $0.peerGeneration
                        == identity.peerGeneration
                    && $0.connectionGeneration
                        == identity.connectionGeneration
                    && $0.deviceEndpoint
                        == identity.deviceEndpoint
            } ?? false
        if let activeKey,
           activeKeyMatchesIdentity,
           !releaseIsPending {
            let leaseKey = LeaseKey(activeKey)
            guard let authorization =
                    authorizationProof(for: leaseKey) else {
                terminalConnectionGeneration =
                    activeKey.connectionGeneration
                resetAcquisitionAttempts()
                _ = releaseActiveBounded()
                return .degraded
            }
            let refreshedKey = leaseKey.authorized(
                by: authorization
            )
            self.activeKey = refreshedKey
            return .selected(refreshedKey)
        }

        if currentLeaseKey != nil,
           releaseIsPending
                || !activeKeyMatchesIdentity {
            let release = releaseActiveBounded()
            if release == .retryableFailure {
                return .degraded
            }
            if terminalConnectionGeneration
                == connectionGeneration {
                return .degraded
            }
        }

        if lastAttemptedIdentity != identity {
            lastAttemptedIdentity = identity
            acquisitionAttemptCount = 0
        }
        guard acquisitionAttemptCount
                < maximumAcquisitionAttemptCount else {
            return .degraded
        }

        let key: LeaseKey
        if let pendingKey {
            key = pendingKey
        } else {
            nextLeaseGeneration = Self.nextNonzero(
                nextLeaseGeneration
            )
            key = LeaseKey(
                monitorEpoch: identity.monitorEpoch,
                deviceGeneration:
                    identity.deviceGeneration,
                peerGeneration: identity.peerGeneration,
                connectionGeneration:
                    identity.connectionGeneration,
                leaseGeneration:
                    nextLeaseGeneration,
                deviceEndpoint:
                    identity.deviceEndpoint
            )
            pendingKey = key
        }

        while acquisitionAttemptCount
                < maximumAcquisitionAttemptCount {
            acquisitionAttemptCount += 1
            switch lease.acquisitionResult(
                generation: key.leaseGeneration,
                targetEndpoint: deviceEndpoint
            ) {
            case .acquired:
                guard let authorization =
                        authorizationProof(for: key) else {
                    terminalConnectionGeneration =
                        key.connectionGeneration
                    acquisitionAttemptCount =
                        maximumAcquisitionAttemptCount
                    _ = releaseActiveBounded()
                    return .degraded
                }
                let authorizedKey = key.authorized(
                    by: authorization
                )
                pendingKey = nil
                activeKey = authorizedKey
                return .selected(authorizedKey)
            case .retryableFailure:
                continue
            case .terminalFailure:
                terminalConnectionGeneration =
                    key.connectionGeneration
                acquisitionAttemptCount =
                    maximumAcquisitionAttemptCount
                _ = releaseActiveBounded()
                return .degraded
            }
        }

        // Retryable pre-write failures can retain the exact generation's
        // retry baseline or pending listener deregistration even without a
        // default-input write. Exhaustion therefore performs one bounded
        // exact cleanup episode. A retryable release preserves activeKey and
        // releaseIsPending for a later lifecycle callback; success clears the
        // key through the existing release path. Keep the exhausted identity
        // and attempt count so no callback can bypass its acquisition budget.
        _ = releaseActiveBounded()
        return .degraded
    }

    private func releaseActive()
        -> ReleaseDisposition {
        guard let leaseKey =
                activeKey.map(LeaseKey.init) ?? pendingKey else {
            releaseIsPending = false
            clockEpochParkingProof = nil
            return .noChange
        }
        switch lease.release(
            generation: leaseKey.leaseGeneration
        ) {
        case .released:
            self.activeKey = nil
            pendingKey = nil
            releaseIsPending = false
            clockEpochParkingProof = nil
            return .released

        case .retryableFailure:
            releaseIsPending = true
            return .retryableFailure

        case .externallySuperseded:
            self.activeKey = nil
            pendingKey = nil
            releaseIsPending = false
            clockEpochParkingProof = nil
            terminalConnectionGeneration =
                leaseKey.connectionGeneration
            recordExternalSupersession(
                peerGeneration:
                    leaseKey.peerGeneration
            )
            return .externallySuperseded
        }
    }

    private func authorizationProof(
        for key: LeaseKey
    ) -> BlackHoleDefaultInputLeaseAuthorization? {
        guard let authorization = lease.authorizationProof(
            generation: key.leaseGeneration,
            targetEndpoint: key.deviceEndpoint
        ),
        authorization.leaseGeneration == key.leaseGeneration,
        authorization.targetEndpoint == key.deviceEndpoint else {
            return nil
        }
        return authorization
    }

    private func releaseActiveBounded()
        -> ReleaseDisposition {
        var result = releaseActive()
        var attemptCount = 1
        while result == .retryableFailure,
              attemptCount < maximumReleaseAttemptCount {
            attemptCount += 1
            result = releaseActive()
        }
        return result
    }

    private func outcome(
        for release: ReleaseDisposition,
        whenNoChange fallback:
            WorldwideBlackHoleDefaultInputOutcome
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        switch release {
        case .noChange:
            return fallback
        case .released, .externallySuperseded:
            return .released
        case .retryableFailure:
            return .degraded
        }
    }

    private func resetAcquisitionAttempts() {
        lastAttemptedIdentity = nil
        acquisitionAttemptCount = 0
    }

    private func recordExternalSupersession(
        peerGeneration: UInt64
    ) {
        guard peerGeneration > 0 else {
            return
        }
        externallySupersededPeerGeneration = max(
            externallySupersededPeerGeneration ?? 0,
            peerGeneration
        )
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }
}
