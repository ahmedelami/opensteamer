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
    let lastFailureCategory:
        WorldwideIPhoneMicrophoneForwardingFailureCategory?

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
            String
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

    private struct Candidate {
        let key: WorldwideIPhoneMicrophoneForwardingKey
        let peer: Peer
        let track: Track
        let deviceUID: String
    }

    private final class Attempt {
        let id: UUID
        let key: WorldwideIPhoneMicrophoneForwardingKey
        let peer: Peer
        let track: Track
        let deviceUID: String
        let output: any WorldwideIPhoneMicrophoneOutput
        var exactTrackAdmitted = false
        var deferredReadyProgress:
            BlackHoleMicrophoneOutputProgressSnapshot?

        init(
            id: UUID,
            candidate: Candidate,
            output: any WorldwideIPhoneMicrophoneOutput
        ) {
            self.id = id
            key = candidate.key
            peer = candidate.peer
            track = candidate.track
            deviceUID = candidate.deviceUID
            self.output = output
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
    private let maximumAttemptCountPerKey: Int
    private let makeAttemptID: @Sendable () -> UUID

    private var activeMonitorEpoch: UUID?
    private var monitorSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var monitoringFailed = false

    private var peer: Peer?
    private var peerGeneration: UInt64 = 0
    private var transportAuthorizationEpoch: UInt64 = 0
    private var transportAuthorized = false
    private var track: Track?
    private var trackGeneration: UInt64 = 0

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

    private var phase: WorldwideIPhoneMicrophoneForwardingPhase
    private var isDriving = false
    private var redriveRequested = false
    private var isStopped = false

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
        retrySleep: @escaping ReadinessSleep = {
            try await Task.sleep(for: .milliseconds(100))
        },
        maximumAttemptCountPerKey: Int = 3,
        makeAttemptID: @escaping @Sendable () -> UUID = {
            UUID()
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
        self.maximumAttemptCountPerKey = max(
            1,
            maximumAttemptCountPerKey
        )
        self.makeAttemptID = makeAttemptID
        phase = policy == .suppressedForLANCoexistence
            ? .suppressedForLANCoexistence
            : .waitingForMonitor
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

        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        self.peer = peer
        self.peerGeneration = peerGeneration
        transportAuthorized = false
        redriveRequested = true
        updateIneligiblePhase()
    }

    func clearPeer(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped else { return }
        invalidateCurrentAttempt()
        disableCurrentTrack()
        track = nil
        peer = nil
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
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard !isStopped else { return }
        transportAuthorized = false
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
        redriveRequested = true
        updateIneligiblePhase()
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

        currentAttempt = nil
        if track === attempt.track {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
        lastFailureCategory = category
        phase = .runtimeFailed
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
            deviceUID: monitorSnapshot?.deviceUID,
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
            candidate.deviceUID
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
            output: output
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
            failAttempt(
                attempt,
                category: .startFailed,
                allowRetry: !Task.isCancelled
            )
            return
        }

        guard candidateStillOwnsAttempt(attempt) else {
            finishSupersededAttempt(attempt)
            return
        }

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
        phase = .checkingReadiness
        await awaitReadiness(
            for: attempt,
            isolation: isolation
        )
    }

    private func awaitReadiness(
        for attempt: Attempt,
        isolation: isolated (any Actor)?
    ) async {
        var previousReadyProgress:
            BlackHoleMicrophoneOutputProgressSnapshot?
        var previousProgress:
            BlackHoleMicrophoneOutputProgressSnapshot?

        for sampleIndex in 0..<readinessSampleLimit {
            guard candidateStillOwnsAttempt(attempt) else {
                finishSupersededAttempt(attempt)
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
                // A running callback clock with successful enqueues is a
                // healthy-silent queue. The remote microphone may still be
                // waiting for permission or its first PCM. Keep this exact
                // attempt admitted instead of consuming its retry budget.
                phase = .awaitingFrames
                return
            }
            previousProgress = progress

            if WorldwideIPhoneMicrophoneForwardingProgressEvaluator
                .isReady(progress) {
                if let previousReadyProgress,
                   WorldwideIPhoneMicrophoneForwardingProgressEvaluator
                    .provesContinuingHealth(
                        previous: previousReadyProgress,
                        current: progress
                    ) {
                    guard candidateStillOwnsAttempt(attempt) else {
                        finishSupersededAttempt(attempt)
                        return
                    }
                    phase = .forwardingHealthy
                    return
                }

                previousReadyProgress = progress
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
              let deviceUID = monitorSnapshot.deviceUID,
              !deviceUID.isEmpty,
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
            deviceUID: deviceUID
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
              candidate.deviceUID == attempt.deviceUID else {
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
              current.deviceUID == candidate.deviceUID else {
            return false
        }
        return true
    }

    private func promoteDeferredReadinessIfPossible(
        attempt: Attempt,
        progress: BlackHoleMicrophoneOutputProgressSnapshot
    ) {
        guard currentAttempt === attempt,
              attempt.exactTrackAdmitted,
              phase == .awaitingFrames
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
            phase = .forwardingHealthy
            return
        }

        attempt.deferredReadyProgress = progress
        phase = .forwardingReady
    }

    private func invalidateCurrentAttempt() {
        guard let attempt = currentAttempt else { return }
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
        guard activeMonitorEpoch != nil,
              let monitorSnapshot else {
            phase = .waitingForMonitor
            return
        }
        guard monitorSnapshot.isAvailable,
              monitorSnapshot.deviceUID != nil else {
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
             .readinessFailed, .runtimeEnqueueFailed,
             .runtimeProgressStalled:
            true
        case .monitoringFailed, .admissionFailed:
            false
        }
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }
}

protocol WorldwideBlackHoleDefaultInputLeasing:
    AnyObject,
    Sendable
{
    func acquisitionResult(
        generation: UInt64,
        targetUID: String
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult
    func release(
        generation: UInt64
    ) -> BlackHoleDefaultInputLeaseReleaseResult
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
    let deviceUID: String
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
        let deviceUID: String
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
    private var activeSelectionConfirmed = false
    private var releaseIsPending = false
    private var terminalConnectionGeneration: UInt64?
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
            if snapshot.isAvailable
                    == monitorSnapshot.isAvailable,
               snapshot.deviceUID
                    == monitorSnapshot.deviceUID {
                if releaseIsPending {
                    return outcome(
                        for: releaseActiveBounded(),
                        whenNoChange: .noChange
                    )
                }
                return .noChange
            }
        }

        monitorSnapshot = snapshot
        if !snapshot.isAvailable
            || snapshot.deviceUID == nil {
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
        guard peerGeneration
                >= highestPeerGenerationSeen else {
            return .noChange
        }
        if peerGeneration
                > highestPeerGenerationSeen {
            highestPeerGenerationSeen = peerGeneration
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
        guard let activeMonitorEpoch,
              let monitorSnapshot else {
            return .waitingForMonitor
        }
        guard monitorSnapshot.isAvailable,
              let deviceUID = monitorSnapshot.deviceUID,
              !deviceUID.isEmpty else {
            return .waitingForDevice
        }
        guard let healthyPeerGeneration else {
            return .noChange
        }
        if terminalConnectionGeneration
                == connectionGeneration,
           activeKey == nil {
            return .degraded
        }

        let identity = CandidateIdentity(
            monitorEpoch: activeMonitorEpoch,
            deviceGeneration:
                monitorSnapshot.deviceGeneration,
            peerGeneration: healthyPeerGeneration,
            connectionGeneration:
                connectionGeneration,
            deviceUID: deviceUID
        )
        let activeKeyMatchesIdentity =
            activeKey.map {
                $0.monitorEpoch == identity.monitorEpoch
                    && $0.deviceGeneration
                        == identity.deviceGeneration
                    && $0.peerGeneration
                        == identity.peerGeneration
                    && $0.connectionGeneration
                        == identity.connectionGeneration
                    && $0.deviceUID
                        == identity.deviceUID
            } ?? false
        if activeSelectionConfirmed,
           activeKeyMatchesIdentity,
           !releaseIsPending {
            return .noChange
        }

        if activeKey != nil,
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

        let key: WorldwideBlackHoleDefaultInputKey
        if let activeKey {
            key = activeKey
        } else {
            nextLeaseGeneration = Self.nextNonzero(
                nextLeaseGeneration
            )
            key = WorldwideBlackHoleDefaultInputKey(
                monitorEpoch: identity.monitorEpoch,
                deviceGeneration:
                    identity.deviceGeneration,
                peerGeneration: identity.peerGeneration,
                connectionGeneration:
                    identity.connectionGeneration,
                leaseGeneration:
                    nextLeaseGeneration,
                deviceUID: identity.deviceUID
            )
            activeKey = key
            activeSelectionConfirmed = false
        }

        while acquisitionAttemptCount
                < maximumAcquisitionAttemptCount {
            acquisitionAttemptCount += 1
            switch lease.acquisitionResult(
                generation: key.leaseGeneration,
                targetUID: deviceUID
            ) {
            case .acquired:
                activeSelectionConfirmed = true
                return .selected(key)
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
        guard let activeKey else {
            releaseIsPending = false
            return .noChange
        }
        switch lease.release(
            generation: activeKey.leaseGeneration
        ) {
        case .released:
            self.activeKey = nil
            activeSelectionConfirmed = false
            releaseIsPending = false
            return .released

        case .retryableFailure:
            releaseIsPending = true
            return .retryableFailure

        case .externallySuperseded:
            self.activeKey = nil
            activeSelectionConfirmed = false
            releaseIsPending = false
            terminalConnectionGeneration =
                activeKey.connectionGeneration
            return .externallySuperseded
        }
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

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }
}
