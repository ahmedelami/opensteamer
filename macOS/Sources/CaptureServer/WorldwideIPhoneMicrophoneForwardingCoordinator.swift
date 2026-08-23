import Foundation

/// Minimal lifecycle surface shared by the production AudioQueue sink and deterministic fakes.
protocol WorldwideIPhoneMicrophoneOutput: AnyObject, Sendable {
    func start() throws
    func stop()
    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot { get }
}

extension WorldwideIPhoneMicrophoneOutput {
    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot {
        .zero
    }
}

extension BlackHoleMicrophoneOutput: WorldwideIPhoneMicrophoneOutput {}

/// Observable outcome of one forwarding-start request.
enum WorldwideIPhoneMicrophoneForwardingStartResult: Equatable, Sendable {
    case started
    case alreadyPublished
    case outputUnavailable
    case superseded
}

/// Actor-owned forwarding state exposed to sequencing tests without native audio hardware.
struct WorldwideIPhoneMicrophoneForwardingSnapshot: Equatable, Sendable {
    let hasPublishedAttempt: Bool
    let isActive: Bool
    let retiringAttemptCount: Int
}

/// Reentrancy-safe ownership of pending and active iPhone-microphone output attempts.
///
/// Every public operation inherits its caller's actor. The current attempt is published before
/// synchronous output startup and before the first peer suspension. A stale completion can stop
/// only its own output and cannot unpublish or mute a replacement attempt.
final class WorldwideIPhoneMicrophoneForwardingCoordinator<
    Peer: AnyObject & Sendable,
    Track: AnyObject & Sendable
> {
    typealias OutputFactory =
        @Sendable (Peer) -> (any WorldwideIPhoneMicrophoneOutput)?
    typealias Admission =
        @Sendable (Peer, Track) async throws -> Void
    typealias TrackDisabler =
        @Sendable (Track) -> Void
    typealias PublicationObserver =
        @Sendable (any WorldwideIPhoneMicrophoneOutput) -> Void

    private final class Attempt {
        enum Phase: Equatable {
            case starting
            case admitting
            case active
        }

        let id = UUID()
        let peer: Peer
        let track: Track
        let output: any WorldwideIPhoneMicrophoneOutput
        var phase: Phase = .starting

        init(
            peer: Peer,
            track: Track,
            output: any WorldwideIPhoneMicrophoneOutput
        ) {
            self.peer = peer
            self.track = track
            self.output = output
        }
    }

    private let makeOutput: OutputFactory
    private let admit: Admission
    private let disableTrack: TrackDisabler
    private let onAttemptPublished: PublicationObserver?
    private var currentAttempt: Attempt?
    private var retiringAttempts: [Attempt] = []

    init(
        makeOutput: @escaping OutputFactory,
        admit: @escaping Admission,
        disableTrack: @escaping TrackDisabler,
        onAttemptPublished: PublicationObserver? = nil
    ) {
        self.makeOutput = makeOutput
        self.admit = admit
        self.disableTrack = disableTrack
        self.onAttemptPublished = onAttemptPublished
    }

    func start(
        isolation: isolated (any Actor)? = #isolation,
        peer: Peer,
        track: Track
    ) async throws -> WorldwideIPhoneMicrophoneForwardingStartResult {
        guard currentAttempt == nil,
              !retiringAttempts.contains(where: {
                  $0.peer === peer && $0.track === track
              }) else {
            return .alreadyPublished
        }
        guard let output = makeOutput(peer) else {
            return .outputUnavailable
        }

        let attempt = Attempt(peer: peer, track: track, output: output)
        currentAttempt = attempt
        onAttemptPublished?(output)

        do {
            try output.start()
        } catch {
            cleanupFailedAttempt(attempt)
            throw error
        }

        guard currentAttempt === attempt else {
            return finishSupersededAttempt(attempt)
        }

        attempt.phase = .admitting
        do {
            try await admit(peer, track)
        } catch {
            cleanupFailedAttempt(attempt)
            throw error
        }

        guard currentAttempt === attempt else {
            return finishSupersededAttempt(attempt)
        }

        attempt.phase = .active
        return .started
    }

    /// Stops and unpublishes only the currently owned attempt.
    func stopCurrent(
        isolation: isolated (any Actor)? = #isolation
    ) {
        guard let attempt = currentAttempt else { return }
        cancelCurrentAttempt(attempt)
    }

    /// Stops only an attempt still owned by the exact peer/track pair supplied by its caller.
    func stopIfCurrent(
        isolation: isolated (any Actor)? = #isolation,
        peer: Peer,
        track: Track
    ) {
        guard let attempt = currentAttempt,
              attempt.peer === peer,
              attempt.track === track else {
            return
        }
        cancelCurrentAttempt(attempt)
    }

    /// Retires only the attempt that owns the exact failed output.
    ///
    /// A delayed report from a retiring output may repeat that output's
    /// idempotent stop, but cannot unpublish or disable a replacement that owns
    /// the same track object.
    @discardableResult
    func handleRuntimeFailure(
        isolation: isolated (any Actor)? = #isolation,
        from output: any WorldwideIPhoneMicrophoneOutput
    ) -> Bool {
        if let attempt = currentAttempt,
           attempt.output === output {
            currentAttempt = nil
            if attempt.phase == .admitting {
                retiringAttempts.append(attempt)
            }
            disableTrack(attempt.track)
            attempt.output.stop()
            return true
        }

        guard let attempt = retiringAttempts.first(where: {
            $0.output === output
        }) else {
            return false
        }

        let replacementOwnsSameTrack = currentAttempt.map {
            $0.track === attempt.track
        } ?? false
        if !replacementOwnsSameTrack {
            disableTrack(attempt.track)
        }
        attempt.output.stop()
        return false
    }

    func snapshot(
        isolation: isolated (any Actor)? = #isolation
    ) -> WorldwideIPhoneMicrophoneForwardingSnapshot {
        WorldwideIPhoneMicrophoneForwardingSnapshot(
            hasPublishedAttempt: currentAttempt != nil,
            isActive: currentAttempt?.phase == .active,
            retiringAttemptCount: retiringAttempts.count
        )
    }

    private func cancelCurrentAttempt(_ attempt: Attempt) {
        guard currentAttempt === attempt else { return }
        currentAttempt = nil
        if attempt.phase == .admitting {
            retiringAttempts.append(attempt)
        }
        disableTrack(attempt.track)
        attempt.output.stop()
    }

    private func cleanupFailedAttempt(_ attempt: Attempt) {
        attempt.output.stop()
        if currentAttempt === attempt {
            currentAttempt = nil
        }
        retiringAttempts.removeAll(where: { $0 === attempt })
    }

    private func finishSupersededAttempt(
        _ attempt: Attempt
    ) -> WorldwideIPhoneMicrophoneForwardingStartResult {
        attempt.output.stop()
        retiringAttempts.removeAll(where: { $0 === attempt })

        let replacementOwnsSameTrack = currentAttempt.map {
            $0.peer === attempt.peer && $0.track === attempt.track
        } ?? false
        if !replacementOwnsSameTrack {
            disableTrack(attempt.track)
        }
        return .superseded
    }
}
