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
    private let readinessSampleLimit: Int
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
    private var attemptedKeys:
        Set<WorldwideIPhoneMicrophoneForwardingKey> = []
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
        readinessSampleLimit: Int = 20,
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
        self.readinessSampleLimit = max(2, readinessSampleLimit)
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
        from output: any WorldwideIPhoneMicrophoneOutput
    ) -> Bool {
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
        lastFailureCategory = .runtimeEnqueueFailed
        phase = .runtimeFailed
        redriveRequested = true
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
        guard !attemptedKeys.contains(candidate.key) else {
            return
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
            failAttempt(attempt, category: .startFailed)
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
                    category: .runtimeEnqueueFailed
                )
                return
            }
            guard progress.queueRunning else {
                failAttempt(
                    attempt,
                    category: .readinessFailed
                )
                return
            }

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
                    category: .readinessFailed
                )
                return
            }
        }

        guard candidateStillOwnsAttempt(attempt) else {
            finishSupersededAttempt(attempt)
            return
        }
        failAttempt(attempt, category: .readinessFailed)
    }

    private var hasUnattemptedEligibleCandidate: Bool {
        guard currentAttempt == nil,
              let candidate = currentCandidate() else {
            return false
        }
        return !attemptedKeys.contains(candidate.key)
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
            WorldwideIPhoneMicrophoneForwardingFailureCategory
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
        redriveRequested = true
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
        redriveRequested = true
    }

    private func rememberAttempted(
        _ key: WorldwideIPhoneMicrophoneForwardingKey
    ) {
        guard attemptedKeys.insert(key).inserted else { return }
        attemptedKeyOrder.append(key)

        let maximumRetainedKeys = 256
        while attemptedKeyOrder.count > maximumRetainedKeys {
            let removed = attemptedKeyOrder.removeFirst()
            attemptedKeys.remove(removed)
        }
        lastAttemptedKey = key
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
           attemptedKeys.contains(candidate.key) {
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
        case .runtimeEnqueueFailed:
            .runtimeFailed
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
    func acquire(
        generation: UInt64,
        targetUID: String
    ) -> Bool
    func release(generation: UInt64)
    func shutdown()
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

    private let policy:
        WorldwideIPhoneMicrophoneForwardingPolicy
    private let lease:
        any WorldwideBlackHoleDefaultInputLeasing

    private var activeMonitorEpoch: UUID?
    private var monitorSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var healthyPeerGeneration: UInt64?
    private var connectionGeneration: UInt64 = 0
    private var activeKey: WorldwideBlackHoleDefaultInputKey?
    private var activeSelectionConfirmed = false
    private var lastAttemptedIdentity: CandidateIdentity?
    private var isStopped = false

    init(
        policy:
            WorldwideIPhoneMicrophoneForwardingPolicy,
        lease:
            any WorldwideBlackHoleDefaultInputLeasing
    ) {
        self.policy = policy
        self.lease = lease
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

        let released = releaseActive()
        activeMonitorEpoch = epoch
        monitorSnapshot = nil
        lastAttemptedIdentity = nil
        return released ? .released : .waitingForMonitor
    }

    func monitoringDidFail()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        guard policy == .enabled else {
            return .suppressed
        }
        _ = releaseActive()
        activeMonitorEpoch = nil
        monitorSnapshot = nil
        lastAttemptedIdentity = nil
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
            || snapshot.deviceUID == nil {
            lastAttemptedIdentity = nil
            return releaseActive()
                ? .released
                : .waitingForDevice
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

        if healthyPeerGeneration == peerGeneration {
            return drive()
        }

        _ = releaseActive()
        healthyPeerGeneration = peerGeneration
        connectionGeneration = Self.nextNonzero(
            connectionGeneration
        )
        lastAttemptedIdentity = nil
        return drive()
    }

    func transportDidBecomeUnhealthy(
        peerGeneration: UInt64
    ) -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped,
              healthyPeerGeneration == peerGeneration else {
            return .noChange
        }
        healthyPeerGeneration = nil
        lastAttemptedIdentity = nil
        return releaseActive()
            ? .released
            : .noChange
    }

    func invalidateCurrentConnection()
        -> WorldwideBlackHoleDefaultInputOutcome {
        guard !isStopped else {
            return .noChange
        }
        healthyPeerGeneration = nil
        lastAttemptedIdentity = nil
        return releaseActive()
            ? .released
            : .noChange
    }

    func shutdown() {
        guard !isStopped else {
            return
        }
        isStopped = true
        healthyPeerGeneration = nil
        lastAttemptedIdentity = nil
        _ = releaseActive()
        lease.shutdown()
    }

    private func drive()
        -> WorldwideBlackHoleDefaultInputOutcome {
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

        let identity = CandidateIdentity(
            monitorEpoch: activeMonitorEpoch,
            deviceGeneration:
                monitorSnapshot.deviceGeneration,
            peerGeneration: healthyPeerGeneration,
            connectionGeneration:
                connectionGeneration,
            deviceUID: deviceUID
        )
        if activeSelectionConfirmed,
           let activeKey,
           activeKey.monitorEpoch
                == identity.monitorEpoch,
           activeKey.peerGeneration
                == identity.peerGeneration,
           activeKey.connectionGeneration
                == identity.connectionGeneration {
            return .noChange
        }
        guard lastAttemptedIdentity != identity else {
            return .noChange
        }

        _ = releaseActive()
        lastAttemptedIdentity = identity
        let key = WorldwideBlackHoleDefaultInputKey(
            monitorEpoch: identity.monitorEpoch,
            deviceGeneration:
                identity.deviceGeneration,
            peerGeneration: identity.peerGeneration,
            connectionGeneration:
                identity.connectionGeneration,
            leaseGeneration: connectionGeneration
        )

        activeKey = key
        activeSelectionConfirmed = false
        guard lease.acquire(
            generation: key.leaseGeneration,
            targetUID: deviceUID
        ) else {
            return .degraded
        }
        activeSelectionConfirmed = true
        return .selected(key)
    }

    @discardableResult
    private func releaseActive() -> Bool {
        guard let activeKey else {
            return false
        }
        self.activeKey = nil
        activeSelectionConfirmed = false
        lease.release(
            generation: activeKey.leaseGeneration
        )
        return true
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }
}
