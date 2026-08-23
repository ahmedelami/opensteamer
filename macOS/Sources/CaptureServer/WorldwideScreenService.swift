import CaptureCore
import AudioToolbox
import CoreMedia
import Foundation
import RemoteSessionCore
import WebRTCTransport

/// Identifies which half of the fail-closed Inactive transition failed.
enum WorldwideScreenInactiveTransitionFailure {
    case nativeStop(any Error)
    case acknowledgement(any Error)
}

/// Linearizes the native ScreenCaptureKit stop with the protocol-level Inactive ACK.
///
/// A viewer must never interpret Inactive as proof that screen capture stopped when the native
/// stop actually threw. The fail-closed callback therefore runs before this operation returns,
/// and the acknowledgement closure is unreachable on that path.
enum WorldwideScreenInactiveTransition {
    /// Stops native capture before acknowledging Inactive, closing the session if stop fails.
    static func perform(
        isolation: isolated (any Actor)? = #isolation,
        stopNativeCapture: () async throws -> Void,
        acknowledgeInactive: () async throws -> Void,
        failClosed: (any Error) async -> Void
    ) async -> WorldwideScreenInactiveTransitionFailure? {
        do {
            try await stopNativeCapture()
        } catch {
            await failClosed(error)
            return .nativeStop(error)
        }

        do {
            try await acknowledgeInactive()
            return nil
        } catch {
            return .acknowledgement(error)
        }
    }
}

/// Rejects callbacks that independent Task scheduling delivered out of native callback order, and
/// rejects every sample that was taken before the currently installed viewer challenge.
enum WorldwideMacHostedCallObservationPolicy {
    static func admits(
        observationSequence: UInt64,
        highestAdmittedSequence: UInt64,
        observationChallenge: SystemAudioMacFaceTimeActivityChallenge?,
        currentChallenge: WebRTCMacHostedCallChallenge?
    ) -> Bool {
        guard observationSequence > highestAdmittedSequence,
              let observationChallenge,
              let currentChallenge,
              currentChallenge.isValid,
              observationChallenge.sequence == currentChallenge.sequence,
              observationChallenge.nonce == currentChallenge.nonce,
              observationChallenge.callEpochNonce
                == currentChallenge.callEpochNonce else {
            return false
        }
        return true
    }
}

/// Converts only a self-consistent native binder state into the protocol-v3 wire state. Inactive
/// is deliberately distinct from a known-empty prospective arm acknowledgement.
enum WorldwideMacHostedCallEvidenceStatePolicy {
    static func state(
        isCausallyBoundActive: Bool,
        isCausallyArmed: Bool
    ) -> WebRTCMacHostedCallEvidence.State? {
        switch (isCausallyBoundActive, isCausallyArmed) {
        case (true, false):
            return .active
        case (false, true):
            return .preflightArmed
        case (false, false):
            return .inactive
        case (true, true):
            return nil
        }
    }
}

/// Requires the native source and stored viewer challenge to belong to the exact current peer.
enum WorldwideMacHostedCallPeerGenerationPolicy {
    static func admits(
        audioPeerGeneration: UInt64?,
        challengePeerGeneration: UInt64?,
        currentPeerGeneration: UInt64
    ) -> Bool {
        currentPeerGeneration > 0
            && audioPeerGeneration == currentPeerGeneration
            && challengePeerGeneration == currentPeerGeneration
    }
}

/// Selects whether a healthy transport should publish, resume, or create system audio.
enum WorldwideSystemAudioStartMode: Equatable {
    case alreadyLive
    case resumeExisting
    case startNew
}

/// Pure ownership policy for the actor's native system-audio source.
enum WorldwideSystemAudioRecoveryPolicy {
    static func startMode(
        isLive: Bool,
        isPausedForRecovery: Bool,
        hasSource: Bool,
        hasSink: Bool,
        hasValidAuthorization: Bool,
        peerGenerationMatches: Bool
    ) -> WorldwideSystemAudioStartMode? {
        if isLive,
           !isPausedForRecovery,
           hasSource,
           hasSink,
           hasValidAuthorization,
           peerGenerationMatches {
            return .alreadyLive
        }
        if !isLive,
           isPausedForRecovery,
           hasSource,
           hasSink,
           !hasValidAuthorization,
           peerGenerationMatches {
            return .resumeExisting
        }
        if !isLive,
           !isPausedForRecovery,
           !hasSource,
           !hasSink,
           !hasValidAuthorization {
            return .startNew
        }
        return nil
    }
}

/// Caps invariant mutations while preserving continuous read-only verification.
struct WorldwideSafeOutputInvariantRetryPolicy: Equatable, Sendable {
    let maximumFailedAttemptCount: Int
    let maximumBackoffTickCount: Int
    let cappedCooldownTickCount: Int
    private(set) var failedAttemptCount = 0
    private(set) var backoffTickCount = 0
    private(set) var cooldownTickCount = 0

    init(
        maximumFailedAttemptCount: Int = 6,
        maximumBackoffTickCount: Int = 16,
        cappedCooldownTickCount: Int = 60
    ) {
        self.maximumFailedAttemptCount = max(
            1,
            maximumFailedAttemptCount
        )
        self.maximumBackoffTickCount = max(
            1,
            maximumBackoffTickCount
        )
        self.cappedCooldownTickCount = max(
            1,
            cappedCooldownTickCount
        )
    }

    mutating func shouldAttemptOnCurrentTick() -> Bool {
        if failedAttemptCount >= maximumFailedAttemptCount {
            guard cooldownTickCount == 0 else {
                cooldownTickCount -= 1
                return false
            }
            failedAttemptCount = 0
            backoffTickCount = 0
        }
        guard backoffTickCount == 0 else {
            backoffTickCount -= 1
            return false
        }
        return true
    }

    mutating func recordFailure() {
        guard failedAttemptCount < maximumFailedAttemptCount else {
            return
        }
        failedAttemptCount += 1
        guard failedAttemptCount < maximumFailedAttemptCount else {
            backoffTickCount = 0
            cooldownTickCount = cappedCooldownTickCount
            return
        }
        let shift = min(failedAttemptCount - 1, 30)
        backoffTickCount = min(
            1 << shift,
            maximumBackoffTickCount
        )
    }

    mutating func reset() {
        failedAttemptCount = 0
        backoffTickCount = 0
        cooldownTickCount = 0
    }
}

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

/// Owns one consume-once rendezvous and its Mac-side WebRTC screen session.
///
/// The invitation authenticates and encrypts signaling. Reachability still comes from
/// ICE/STUN and, when a direct candidate pair is impossible, the configured TURN service.
actor WorldwideScreenService {
    /// Finishes once the consume-once media rendezvous has been fully torn down.
    nonisolated let completion: AsyncStream<Void>

    /// Formats peer state with the host PID so duplicate-process diagnostics remain actionable.
    nonisolated static func peerStateLogMessage(
        state: String,
        processIdentifier: Int32
    ) -> String {
        "Worldwide WebRTC peer state: \(state) pid=\(processIdentifier)"
    }

    /// Binds the physical default-input boundary to the exact host process and peer.
    nonisolated static func defaultInputSelectionLogMessage(
        routingEpoch: String,
        peerGeneration: UInt64,
        deviceGeneration: UInt64,
        processIdentifier: Int32
    ) -> String {
        "Worldwide authenticated media route selected virtual microphone default input " +
            "routingEpoch=\(routingEpoch) " +
            "peerGeneration=\(peerGeneration) " +
            "deviceGeneration=\(deviceGeneration) " +
            "pid=\(processIdentifier)"
    }

    /// One nonsecret, privacy-safe identifier for this service's audio-routing evidence.
    nonisolated static func makeBlackHoleRoutingEpoch() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    nonisolated static func iPhoneMicrophoneRuntimeFailureCategory(
        for error: BlackHoleMicrophoneOutputError
    ) -> WorldwideIPhoneMicrophoneForwardingFailureCategory {
        switch error {
        case .operation:
            return .runtimeEnqueueFailed
        case .progressStalled:
            return .runtimeProgressStalled
        case .formatUnsafe:
            return .formatUnsafe
        case .sharedClockUnsafe:
            return .sharedClockUnsafe
        }
    }

    nonisolated static func iPhoneMicrophoneRuntimeFailureLogMessage(
        error: BlackHoleMicrophoneOutputError
    ) -> String {
        switch error {
        case .formatUnsafe:
            return "iPhone microphone forwarding rejected the current " +
                "peer and virtual microphone pair because its output format/readback " +
                "is unsafe; automatic restart is blocked until the peer or " +
                "pair generation changes: " +
                error.localizedDescription
        case .sharedClockUnsafe:
            return "iPhone microphone forwarding rejected the current " +
                "peer and virtual microphone pair because its shared clock is " +
                "unsafe for FaceTime; automatic restart is blocked until " +
                "the peer or pair generation changes: " +
                error.localizedDescription
        case .operation, .progressStalled:
            return "iPhone microphone forwarding encountered an output " +
                "runtime failure and ran its bounded restart policy: " +
                error.localizedDescription
        }
    }

    nonisolated static func hiddenWriterSelectionLogMessage(
        routingEpoch: String,
        peerGeneration: UInt64,
        deviceGeneration: UInt64,
        selectionProven: Bool,
        processIdentifier: Int32
    ) -> String? {
        guard selectionProven,
              peerGeneration > 0,
              deviceGeneration > 0 else {
            return nil
        }
        return "Worldwide iPhone microphone hidden writer selected " +
            "routingEpoch=\(routingEpoch) " +
            "peerGeneration=\(peerGeneration) " +
            "deviceGeneration=\(deviceGeneration) " +
            "pid=\(processIdentifier)"
    }

    /// Privacy-safe progress telemetry: no device UID, track ID, nonce, or attempt UUID.
    nonisolated static func iPhoneMicrophoneForwardingLogMessage(
        _ snapshot: WorldwideIPhoneMicrophoneForwardingHostSnapshot
    ) -> String {
        let progress = snapshot.progress
        let content = progress.pcmContent
        let decoded = progress.decodedContent
        let contentScalars = String(
            format:
                "pcmRMS=%.6f pcmRMSdBFS=%.2f " +
                "pcmPeak=%.6f pcmPeakdBFS=%.2f " +
                "pcmDC=%.6f pcmZeroFraction=%.6f " +
                "pcmClippingFraction=%.6f",
            content.metrics.rms,
            content.metrics.rmsDBFS,
            content.metrics.peak,
            content.metrics.peakDBFS,
            content.metrics.dc,
            content.metrics.zeroFraction,
            content.metrics.clippingFraction
        )
        let decodedScalars = String(
            format:
                "decRMS=%.6f decRMSdBFS=%.2f " +
                "decPeak=%.6f decPeakdBFS=%.2f " +
                "decDC=%.6f decZeroFraction=%.6f " +
                "decClippingFraction=%.6f",
            decoded.metrics.rms,
            decoded.metrics.rmsDBFS,
            decoded.metrics.peak,
            decoded.metrics.peakDBFS,
            decoded.metrics.dc,
            decoded.metrics.zeroFraction,
            decoded.metrics.clippingFraction
        )
        return "Worldwide iPhone microphone forwarding " +
            "phase=\(snapshot.phase.rawValue) " +
            "inputEndpointAvailable=\(snapshot.deviceUID != nil) " +
            "hiddenSinkAvailable=\(snapshot.sinkDeviceUID != nil) " +
            "hiddenWriterSelectionProven=" +
                "\(snapshot.hiddenWriterSelectionProven) " +
            "transport=\(snapshot.transportAuthorized) " +
            "trackAdmitted=\(snapshot.exactTrackAdmitted) " +
            "queueRunning=\(snapshot.queueRunning) " +
            "callbacks=\(progress.postStartCallbackCount) " +
            "pulls=\(progress.successfulPullCount) " +
            "frames=\(progress.successfulFrameCount) " +
            "silenceFallbacks=\(progress.silenceFallbackCount) " +
            "enqueueFailures=\(progress.enqueueFailureCount) " +
            "pcmLifecycleGeneration=\(content.lifecycleGeneration) " +
            "pcmWindowSequence=\(content.windowSequence) " +
            "pcmCompletedFrames=\(content.completedFrameCount) " +
            "pcmSourceStartFrame=\(content.sourceStartFrame) " +
            "pcmSourceEndFrame=\(content.sourceEndFrame) " +
            "pcmWindowFrames=\(content.windowFrameCount) " +
            "pcmWindowBytes=\(content.windowByteCount) " +
            "boundDecGeneration=" +
                "\(progress.boundDecodedPlayoutGeneration) " +
            "boundDecRenderFloor=" +
                "\(progress.boundDecodedRenderCallFloor) " +
            contentScalars + " " +
            "decGeneration=\(decoded.playoutGeneration) " +
            "decCalls=\(decoded.renderCallCount) " +
            "decRequestedFrames=\(decoded.requestedFrameCount) " +
            "decRequestedBytes=\(decoded.requestedByteCount) " +
            "decReturnedBytes=\(decoded.returnedByteCount) " +
            "decNativeSuccess=" +
                "\(decoded.nativeSuccessRenderCallCount) " +
            "decNativeFailure=" +
                "\(decoded.nativeFailureRenderCallCount) " +
            "decExactContracts=\(decoded.exactBufferContractCount) " +
            "decAnalyzedCalls=\(decoded.analyzedRenderCallCount) " +
            "decAnalyzedFrames=\(decoded.analyzedFrameCount) " +
            "decAnalyzedBytes=\(decoded.analyzedByteCount) " +
            "decDropped=\(decoded.droppedTelemetryRenderCallCount) " +
            "decContractMismatch=\(decoded.bufferContractMismatchCount) " +
            "decPendingFrames=\(decoded.pendingWindowFrameCount) " +
            "decLatestCall=\(decoded.latestRenderCall) " +
            "decLatestStatus=\(decoded.latestRenderStatus) " +
            "decLatestRequestedFrames=" +
                "\(decoded.latestRequestedFrameCount) " +
            "decLatestRequestedBytes=" +
                "\(decoded.latestRequestedByteCount) " +
            "decLatestReturnedBytes=" +
                "\(decoded.latestReturnedByteCount) " +
            "decLatestExact=\(decoded.latestBufferContractWasExact) " +
            "decHasWindow=\(decoded.hasCompletedWindow) " +
            "decWindowSequence=\(decoded.windowSequence) " +
            "decWindowGeneration=\(decoded.windowGeneration) " +
            "decSourceStartFrame=\(decoded.windowSourceStartFrame) " +
            "decSourceEndFrame=\(decoded.windowSourceEndFrame) " +
            "decWindowFrames=\(decoded.windowFrameCount) " +
            "decWindowBytes=\(decoded.windowByteCount) " +
            decodedScalars + " " +
            "decAllZero=\(decoded.windowIsAllZero) " +
            "decFrozenBlocks=\(decoded.frozenBlockCount) " +
            "decLongestFrozenRun=\(decoded.longestFrozenBlockRun) " +
            "contentWindowsAlign=\(progress.contentWindowsAlign) " +
            "contentFingerprintsMatch=" +
                "\(progress.alignedContentFingerprintsMatch) " +
            "mediaSample=\(snapshot.inboundMediaSampleSequence) " +
            "mediaAdvances=\(snapshot.inboundMediaAdvancementCount) " +
            "mediaStale=\(snapshot.consecutiveStaleInboundMediaSamples) " +
            "mediaFresh=\(snapshot.inboundMediaFresh) " +
            "failure=\(snapshot.lastFailureCategory?.rawValue ?? "none")"
    }

    /// Privacy-safe receiver evidence: aggregate RTP/media counters only.
    nonisolated static func inboundAudioRTPLogMessage(
        packets: UInt64?,
        bytes: UInt64?,
        totalAudioEnergy: Double?,
        audioLevel: Double?
    ) -> String {
        "Worldwide inbound audio RTP packets="
            + (packets.map { String($0) } ?? "unknown")
            + " bytes=" + (bytes.map { String($0) } ?? "unknown")
            + " energy=" + (totalAudioEnergy.map {
                String(format: "%.6f", $0)
            } ?? "unknown")
            + " level=" + (audioLevel.map {
                String(format: "%.6f", $0)
            } ?? "unknown")
    }

    private let invitation: RemoteInvitationCode?
    private let signaling: RendezvousSignalingClient
    private let icePolicy: WebRTCICEPolicy
    private let displayID: UInt32?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let maximumVideoBitrate: Int
    private let remoteInputController: MacRemoteInputController
    private let iPhoneMicrophoneForwardingPolicy:
        WorldwideIPhoneMicrophoneForwardingPolicy
    private let blackHoleDeviceAvailabilityMonitor =
        BlackHoleDeviceAvailabilityMonitor()
    private let blackHoleDefaultInputLease =
        BlackHoleDefaultInputLease()
    private let worldwideSafeOutputInvariant =
        WorldwideSafeOutputInvariant()
    private let blackHoleMicrophoneOutputAuthorizationGate =
        BlackHoleMicrophoneOutputAuthorizationGate()
    private let blackHoleRoutingEpoch =
        WorldwideScreenService.makeBlackHoleRoutingEpoch()
    private let blackHoleAudioRoutingCleanupID =
        UUID()
    private let maximumBlackHoleAudioRoutingCleanupEpisodeCount =
        1
    private let logger: Logger
    private let completionContinuation: AsyncStream<Void>.Continuation

    private var signalingTask: Task<Void, Never>?
    private var peerEventTask: Task<Void, Never>?
    private var peer: WebRTCPeer?
    private var recoveryCoordinator: ICERecoveryCoordinator?
    private var peerGeneration: UInt64 = 0
    private var highestRestartRequestID: UInt64?
    private var peerIsConnected = false
    private var iceIsConnected = false
    private var controlChannelIsOpen = false
    private var isRecovering = false
    private var recoveryProofRequired = false
    private var recoveryProofEpoch: UInt64 = 0
    private var restartAnswerAwaitingEpoch: UInt64?
    private var restartAnswerAppliedEpoch: UInt64?
    private var pendingRecoveryProofRequest: PendingRecoveryProofRequest?
    private var recoveryProofAcknowledgementInFlight: PendingRecoveryProofRequest?
    private var recoveryProofAuthorization: WebRTCControlAuthorization?
    private var captureSource: ScreenVideoCaptureSource?
    private var captureSink: WorldwideScreenSampleSink?
    private var captureAuthorization: WebRTCControlAuthorization?
    private var captureDisplayID: UInt32?
    private var audioSource: SystemAudioCaptureSource?
    private var audioSink: WorldwideSystemAudioSampleSink?
    private var audioAuthorization: WebRTCAudioAuthorization?
    private var audioPeerGeneration: UInt64?
    private var systemAudioStartInProgress = false
    private var systemAudioIsLive = false
    private var systemAudioIsPausedForTransportRecovery = false
    private var macHostedCallChallenge:
        WebRTCMacHostedCallChallenge?
    private var macHostedCallChallengePeerGeneration: UInt64?
    private var highestMacFaceTimeObservationSequence: UInt64 = 0
    private var blackHoleDeviceMonitorEpoch: UUID?
    private var safeOutputInvariantMonitoringEpoch:
        WorldwideSafeOutputInvariantMonitoringEpoch?
    private var safeOutputInvariantAuthorization:
        WorldwideSafeOutputInvariantAuthorization?
    /// Exact endpoint-pair inventory proof incorporated by the admission that
    /// last opened the realtime writer gate. A delayed actor reconciliation
    /// may be discarded only when this proof already includes its raw event.
    private struct BlackHoleEndpointPairAuthorization: Equatable {
        let monitorEpoch: UUID
        let deviceGeneration: UInt64
        let acceptedInventoryChangeSequence: UInt64
    }
    private var blackHoleEndpointPairAuthorization:
        BlackHoleEndpointPairAuthorization?
    private var blackHoleDefaultInputAuthorization:
        BlackHoleDefaultInputLeaseAuthorization?
    struct SharedClockBlockedPeerPair: Equatable {
        let monitorEpoch: UUID
        let deviceGeneration: UInt64
        let peerGeneration: UInt64

        init(
            forwardingKey:
                WorldwideIPhoneMicrophoneForwardingKey
        ) {
            monitorEpoch = forwardingKey.monitorEpoch
            deviceGeneration = forwardingKey.deviceGeneration
            peerGeneration = forwardingKey.peerGeneration
        }

        func matches(
            peerGeneration: UInt64,
            snapshot: BlackHoleDeviceAvailabilitySnapshot
        ) -> Bool {
            self.peerGeneration == peerGeneration
                && monitorEpoch == snapshot.monitorEpoch
                && deviceGeneration == snapshot.deviceGeneration
        }
    }
    struct FormatUnsafeBlockedPeerPair: Equatable {
        let monitorEpoch: UUID
        let deviceGeneration: UInt64
        let peerGeneration: UInt64

        init(
            forwardingKey:
                WorldwideIPhoneMicrophoneForwardingKey
        ) {
            monitorEpoch = forwardingKey.monitorEpoch
            deviceGeneration = forwardingKey.deviceGeneration
            peerGeneration = forwardingKey.peerGeneration
        }

        func matches(
            peerGeneration: UInt64,
            snapshot: BlackHoleDeviceAvailabilitySnapshot
        ) -> Bool {
            self.peerGeneration == peerGeneration
                && monitorEpoch == snapshot.monitorEpoch
                && deviceGeneration == snapshot.deviceGeneration
        }
    }
    private var sharedClockBlockedPeerPair:
        SharedClockBlockedPeerPair?
    private var formatUnsafeBlockedPeerPair:
        FormatUnsafeBlockedPeerPair?
    private lazy var blackHoleDefaultInput =
        WorldwideBlackHoleDefaultInputCoordinator(
            policy: iPhoneMicrophoneForwardingPolicy,
            lease: blackHoleDefaultInputLease
        )
    private lazy var iPhoneMicrophoneForwarding =
        WorldwideIPhoneMicrophoneForwardingDriver<
            WebRTCPeer,
            WebRTCRemoteAudioTrack
        >(
            policy: iPhoneMicrophoneForwardingPolicy,
            makeOutput: { [weak self] peer, hiddenEndpoint in
                guard let self,
                      let source = peer.macDecodedAudioSource,
                      let authorizationGate =
                        self.blackHoleMicrophoneOutputAuthorizationGate
                else {
                    return nil
                }
                return BlackHoleMicrophoneOutput(
                    source: source,
                    expectedHiddenEndpoint: hiddenEndpoint,
                    authorizationGate: authorizationGate,
                    runtimeFailureHandler: { [weak self] output, error in
                        Task { [weak self] in
                            await self?.iPhoneMicrophoneOutputDidFail(
                                output: output,
                                error: error
                            )
                        }
                    }
                )
            },
            startOutput: { output in
                try output.start()
            },
            admit: { peer, track in
                try await peer.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
                    track
                )
            },
            disableTrack: { track in
                track.setEnabled(false)
            },
            sharedClockFailureHandler: {
                [weak self] key, rejection in
                await self?.iPhoneMicrophoneSharedClockDidFail(
                    key: key,
                    rejection: rejection
                )
            },
            formatFailureHandler: {
                [weak self] key, rejection in
                await self?.iPhoneMicrophoneFormatDidFail(
                    key: key,
                    rejection: rejection
                )
            }
        )
    private var activeInputCapability: WebRTCInputCapability?
    private var activeInputAuthorization: WebRTCInputAuthorization?
    private var isStarted = false
    private var isStopped = false
    private var safeOutputInvariantNeedsRedrive = false
    private var safeOutputInvariantVerificationWasFailing = false
    private var safeOutputInvariantRetryPolicy =
        WorldwideSafeOutputInvariantRetryPolicy()

    /// Fail-closed aggregate gate required before exposing either media source.
    private var transportAllowsCapture: Bool {
        peerIsConnected
            && iceIsConnected
            && controlChannelIsOpen
            && !isRecovering
            && !isStopped
    }

    /// Creates a legacy consume-once session with a newly generated invitation capability.
    init(
        endpoint: URL,
        forceRelay: Bool,
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        maximumVideoBitrate: Int,
        remoteInputController: MacRemoteInputController,
        iPhoneMicrophoneForwardingPolicy:
            WorldwideIPhoneMicrophoneForwardingPolicy = .enabled,
        logger: Logger
    ) throws {
        let completionPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = completionPair.stream
        completionContinuation = completionPair.continuation
        let invitation = try RemoteInvitationCode.generate()
        self.invitation = invitation
        signaling = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host
        )
        icePolicy = forceRelay ? .relayOnly : .directPreferred
        self.displayID = displayID
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.maximumVideoBitrate = maximumVideoBitrate
        self.remoteInputController = remoteInputController
        self.iPhoneMicrophoneForwardingPolicy =
            iPhoneMicrophoneForwardingPolicy
        self.logger = logger
    }

    /// Creates a paired reconnect session from a fresh authenticated rendezvous credential.
    init(
        endpoint: URL,
        sessionCredential: RemoteRendezvousCredential,
        forceRelay: Bool,
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        maximumVideoBitrate: Int,
        remoteInputController: MacRemoteInputController,
        iPhoneMicrophoneForwardingPolicy:
            WorldwideIPhoneMicrophoneForwardingPolicy = .enabled,
        logger: Logger
    ) throws {
        let completionPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = completionPair.stream
        completionContinuation = completionPair.continuation
        invitation = nil
        signaling = try RendezvousSignalingClient(
            endpoint: endpoint,
            credential: sessionCredential,
            role: .host
        )
        icePolicy = forceRelay ? .relayOnly : .directPreferred
        self.displayID = displayID
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.maximumVideoBitrate = maximumVideoBitrate
        self.remoteInputController = remoteInputController
        self.iPhoneMicrophoneForwardingPolicy =
            iPhoneMicrophoneForwardingPolicy
        self.logger = logger
    }

    /// Starts the outbound rendezvous connection and deliberately returns the secret once
    /// for presentation to the user. Callers must never put this value in routine logs.
    func start() async throws -> String {
        guard let invitation else {
            throw WorldwideScreenServiceError.invalidLifecycle
        }
        try await startSignaling()
        logger.info("Worldwide screen host is waiting for a one-time viewer")
        return invitation.exportedCode
    }

    /// Starts a fresh paired-device media rendezvous without exposing session credentials.
    func startPairedSession() async throws {
        guard invitation == nil else {
            throw WorldwideScreenServiceError.invalidLifecycle
        }
        try await startSignaling()
        logger.info("Worldwide screen host is waiting for the paired iPhone media session")
    }

    /// Starts signaling once and supervises its event stream in a child task.
    private func startSignaling() async throws {
        guard !isStarted, !isStopped else {
            throw WorldwideScreenServiceError.invalidLifecycle
        }
        isStarted = true

        await startIPhoneMicrophoneDeviceMonitoringIfNeeded()
        do {
            let events = try await signaling.connect()
            signalingTask = Task { [weak self] in
                await self?.consumeSignalingEvents(events)
            }
        } catch {
            isStopped = true
            shutdownBlackHoleAudioRouting()
            iPhoneMicrophoneForwarding.shutdown()
            completionContinuation.finish()
            throw error
        }
    }

    /// Revokes all capabilities before stopping native capture, WebRTC, and signaling.
    ///
    /// Teardown is idempotent. Authorization and forwarding gates close synchronously
    /// before any `await`, so actor reentrancy cannot leak a late media or input callback.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        safeOutputInvariantNeedsRedrive = false
        safeOutputInvariantVerificationWasFailing = false
        safeOutputInvariantRetryPolicy.reset()

        shutdownBlackHoleAudioRouting()
        iPhoneMicrophoneForwarding.shutdown()
        signalingTask?.cancel()
        signalingTask = nil
        peerEventTask?.cancel()
        peerEventTask = nil
        let coordinator = recoveryCoordinator
        recoveryCoordinator = nil
        peerGeneration &+= 1
        peerIsConnected = false
        iceIsConnected = false
        controlChannelIsOpen = false
        isRecovering = false
        recoveryProofRequired = false
        recoveryProofEpoch &+= 1
        restartAnswerAwaitingEpoch = nil
        restartAnswerAppliedEpoch = nil
        pendingRecoveryProofRequest = nil
        recoveryProofAcknowledgementInFlight = nil
        recoveryProofAuthorization?.revoke()
        recoveryProofAuthorization = nil
        revokeCaptureAuthorization()
        revokeSystemAudioAuthorization()
        captureSink?.stopForwarding()
        audioSink?.stopForwarding()
        await coordinator?.cancel()
        do {
            try await stopScreenCapture()
        } catch {
            // Session shutdown must continue through peer/signaling close even when
            // ScreenCaptureKit cannot confirm its native stop.
            logger.error(
                "Worldwide screen capture stop failed during session close: " +
                error.localizedDescription
            )
        }
        await stopSystemAudio()
        if let peer {
            await peer.close(reason: .hostStopped)
        }
        self.peer = nil
        await signaling.close()
        completionContinuation.yield(())
        completionContinuation.finish()
    }

    // MARK: - Rendezvous signaling

    /// Serially consumes rendezvous events and closes the session on terminal failure.
    private func consumeSignalingEvents(
        _ events: RendezvousSignalingClient.EventStream
    ) async {
        do {
            for try await event in events {
                guard !isStopped else { return }
                try await handleSignalingEvent(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isStopped else { return }
            logger.error("Worldwide rendezvous session ended: \(error.localizedDescription)")
            await stop()
        }
    }

    /// Applies invitation, ICE, and peer-lifecycle events in protocol order.
    private func handleSignalingEvent(_ event: RendezvousSignalingEvent) async throws {
        switch event {
        case .waiting(let invitationExpiresAt):
            let remaining = max(0, Int(invitationExpiresAt.timeIntervalSinceNow.rounded()))
            if invitation == nil {
                logger.info("Fresh paired media rendezvous expires in about \(remaining) seconds")
            } else {
                logger.info("One-time invitation is waiting (expires in about \(remaining) seconds)")
            }

        case .ready(_, _, let iceServers):
            guard peer == nil else { return }
            try await startPeer(iceServers: iceServers)

        case .signal(.iceRestartRequest(let request)):
            guard peer != nil, let recoveryCoordinator else {
                throw WorldwideScreenServiceError.signalBeforeReady
            }
            if let highestRestartRequestID,
               request.requestID <= highestRestartRequestID {
                return
            }
            highestRestartRequestID = request.requestID
            // Arm the proof gate before the first await. Otherwise an already-queued native
            // connected/open event can cancel the coordinator's zero-delay restart.
            installRecoveryProofBoundary(awaitingAnswer: false)
            await stopCaptureForTransportUncertainty(
                "the viewer requested route recovery"
            )
            await recoveryCoordinator.restartRequested()

        case .signal(let payload):
            guard let peer else {
                throw WorldwideScreenServiceError.signalBeforeReady
            }
            let answerEpoch: UInt64?
            if case .answer = payload,
               recoveryProofRequired,
               restartAnswerAwaitingEpoch == recoveryProofEpoch {
                answerEpoch = recoveryProofEpoch
            } else {
                answerEpoch = nil
            }
            try await peer.receive(payload)
            guard !isStopped, self.peer === peer else { return }
            if let answerEpoch,
               answerEpoch == recoveryProofEpoch,
               restartAnswerAwaitingEpoch == answerEpoch,
               recoveryProofRequired {
                // This is deliberately after `peer.receive` returns: only then is the answer
                // installed and the peer's signaling generation stable.
                restartAnswerAwaitingEpoch = nil
                restartAnswerAppliedEpoch = answerEpoch
                await completePendingRecoveryProofIfPossible(
                    peer: peer,
                    epoch: answerEpoch
                )
            }

        case .peerLeft:
            logger.info("Worldwide viewer disconnected; the media rendezvous is consumed")
            await stop()

        case .serverError(let error):
            throw WorldwideScreenServiceError.rendezvous(error)
        }
    }

    // MARK: - WebRTC peer lifecycle

    /// Creates a fresh WebRTC generation and its bounded ICE recovery supervisor.
    private func startPeer(iceServers: [RemoteICEServer]) async throws {
        let peer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .host,
                iceServers: iceServers,
                icePolicy: icePolicy,
                maximumVideoBitrate: maximumVideoBitrate
            )
        )
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput.invalidateCurrentConnection()
        )
        safeOutputInvariantNeedsRedrive = false
        safeOutputInvariantVerificationWasFailing = false
        safeOutputInvariantRetryPolicy.reset()
        peerGeneration &+= 1
        let generation = peerGeneration
        highestRestartRequestID = nil
        peerIsConnected = false
        iceIsConnected = false
        controlChannelIsOpen = false
        isRecovering = false
        recoveryProofRequired = false
        recoveryProofEpoch &+= 1
        restartAnswerAwaitingEpoch = nil
        restartAnswerAppliedEpoch = nil
        pendingRecoveryProofRequest = nil
        recoveryProofAcknowledgementInFlight = nil
        recoveryProofAuthorization?.revoke()
        recoveryProofAuthorization = nil
        revokeCaptureAuthorization()
        revokeSystemAudioAuthorization()
        iPhoneMicrophoneForwarding.clearPeer()
        await stopSystemAudio()

        let coordinator = ICERecoveryCoordinator(
            restart: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.beginICERestart(
                    peer: peer,
                    peerGeneration: generation
                )
            },
            exhausted: { [weak self] in
                await self?.recoveryDidExhaust(peerGeneration: generation)
            }
        )
        self.peer = peer
        iPhoneMicrophoneForwarding.replacePeer(
            peer: peer,
            peerGeneration: generation
        )
        recoveryCoordinator = coordinator
        let events = peer.events
        peerEventTask = Task { [weak self] in
            await self?.consumePeerEvents(
                events,
                sourcePeer: peer,
                sourcePeerGeneration: generation
            )
        }
        try await peer.startStatistics()
        try await peer.start()
        logger.info("Worldwide WebRTC negotiation started")
    }

    /// Consumes native peer events until normal stop or an unexpected stream end.
    private func consumePeerEvents(
        _ events: AsyncStream<WebRTCTransportEvent>,
        sourcePeer: WebRTCPeer,
        sourcePeerGeneration: UInt64
    ) async {
        for await event in events {
            guard !isStopped,
                  peer === sourcePeer,
                  peerGeneration == sourcePeerGeneration else {
                return
            }
            do {
                try await handlePeerEvent(
                    event,
                    sourcePeer: sourcePeer,
                    sourcePeerGeneration: sourcePeerGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard peer === sourcePeer,
                      peerGeneration == sourcePeerGeneration else {
                    return
                }
                logger.error("Worldwide WebRTC session failed: \(error.localizedDescription)")
                await stop()
                return
            }
        }
        guard !Task.isCancelled,
              !isStopped,
              peer === sourcePeer,
              peerGeneration == sourcePeerGeneration else {
            return
        }
        logger.error("Worldwide WebRTC event stream ended unexpectedly")
        await stop()
    }

    /// Updates transport health, routes protocol requests, and emits sanitized diagnostics.
    private func handlePeerEvent(
        _ event: WebRTCTransportEvent,
        sourcePeer: WebRTCPeer,
        sourcePeerGeneration: UInt64
    ) async throws {
        switch event {
        case .outboundSignal(let payload):
            try await signaling.send(payload)

        case .peerStateChanged(let state):
            logger.info(
                Self.peerStateLogMessage(
                    state: state.rawValue,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                )
            )
            switch state {
            case .new, .connecting:
                let previouslyAuthorizedRoute = peerIsConnected
                    || captureSource != nil
                    || audioSource != nil
                peerIsConnected = false
                if previouslyAuthorizedRoute {
                    await enterRecovery(reason: "peer route became indeterminate")
                    await recoveryCoordinator?.iceStateChanged(.disconnected)
                }
            case .connected:
                peerIsConnected = true
                if recoveryProofRequired, let peer {
                    await completePendingRecoveryProofIfPossible(
                        peer: peer,
                        epoch: recoveryProofEpoch
                    )
                } else if await markRecoveryHealthyIfPossible() {
                    await recoveryCoordinator?.iceStateChanged(.connected)
                }
            case .disconnected:
                peerIsConnected = false
                await enterRecovery(reason: "peer disconnected")
                await recoveryCoordinator?.iceStateChanged(.disconnected)
            case .failed:
                peerIsConnected = false
                await enterRecovery(reason: "peer failed")
                await recoveryCoordinator?.iceStateChanged(.failed)
            case .closed:
                await stop()
            }

        case .iceStateChanged(let state):
            logger.debug("Worldwide ICE state: \(state.rawValue)")
            switch state {
            case .connected, .completed:
                iceIsConnected = true
                if recoveryProofRequired, let peer {
                    await completePendingRecoveryProofIfPossible(
                        peer: peer,
                        epoch: recoveryProofEpoch
                    )
                } else if await markRecoveryHealthyIfPossible() {
                    await recoveryCoordinator?.iceStateChanged(state)
                }
            case .disconnected, .failed:
                iceIsConnected = false
                await enterRecovery(reason: "ICE route unavailable")
                await recoveryCoordinator?.iceStateChanged(state)
            case .closed:
                iceIsConnected = false
                await recoveryCoordinator?.iceStateChanged(state)
                await stop()
            case .new, .checking, .unknown:
                let previouslyAuthorizedRoute = iceIsConnected
                    || captureSource != nil
                    || audioSource != nil
                iceIsConnected = false
                if previouslyAuthorizedRoute {
                    // Initial ICE negotiation is allowed to move through these states. Once a
                    // route has carried an authorized capture, however, moving back to an
                    // indeterminate state is an uncertainty boundary and must fail closed.
                    await enterRecovery(reason: "ICE route became indeterminate")
                    await recoveryCoordinator?.iceStateChanged(.disconnected)
                }
            }

        case .iceGatheringStateChanged(let state):
            logger.debug("Worldwide ICE gathering: \(state.rawValue)")

        case .dataChannelStateChanged(let state):
            logger.debug("Worldwide control channel: \(state.rawValue)")
            let wasOpen = controlChannelIsOpen
            controlChannelIsOpen = state == .open
            if state == .open {
                if recoveryProofRequired, let peer {
                    await completePendingRecoveryProofIfPossible(
                        peer: peer,
                        epoch: recoveryProofEpoch
                    )
                } else if await markRecoveryHealthyIfPossible() {
                    await recoveryCoordinator?.iceStateChanged(.connected)
                }
            }
            if state == .closing || state == .closed || (wasOpen && state != .open) {
                await enterRecovery(reason: "control channel unavailable")
                await recoveryCoordinator?.iceStateChanged(.failed)
            }

        case .controlRequestReceived(let request):
            await handleControlRequest(request)

        case .controlAcknowledgementReceived(_, inputAuthorization: _):
            // Only the viewer receives host acknowledgements.
            break

        case .inputRequestReceived(let request, authorization: let authorization):
            await handleRemoteInputRequest(request, authorization: authorization)

        case .inputFeedbackReceived:
            // Only the viewer receives host input feedback.
            break

        case .inputSessionInvalidated(let reason):
            revokeRemoteInputAuthorization()
            logger.info("Worldwide remote input stopped: \(reason)")

        case .macHostedCallChallengeReceived(let challenge):
            installMacHostedCallChallenge(
                challenge,
                sourcePeer: sourcePeer,
                sourcePeerGeneration: sourcePeerGeneration
            )

        case .macHostedCallEvidenceChanged:
            // Only the iPhone viewer receives host-originated call evidence.
            break

        case .controlReceived:
            // Legacy signaling controls deliberately cannot start worldwide capture because they
            // do not provide the request ID and completion acknowledgement required by the v2 path.
            logger.debug("Ignored legacy worldwide screen control without acknowledgement")

        case .routeChanged(let route):
            logger.info("Worldwide WebRTC route: \(route.kind.rawValue)")

        case .statistics(let snapshot):
            guard peer === sourcePeer,
                  peerGeneration == sourcePeerGeneration else {
                return
            }
            let routingAdmission =
                admitBlackHoleInputWithinSafeOutputFence()
            if let currentBlackHoleSnapshot =
                    routingAdmission.snapshot {
                await iPhoneMicrophoneForwarding.updateDeviceSnapshot(
                    currentBlackHoleSnapshot
                )
                await authorizeIPhoneMicrophoneForwardingIfPossible()
            }
            guard peer === sourcePeer,
                  peerGeneration == sourcePeerGeneration else {
                return
            }
            let inbound = snapshot.inboundAudio
            await iPhoneMicrophoneForwarding
                .updateInboundMediaFreshness(
                    peer: sourcePeer,
                    peerGeneration: sourcePeerGeneration,
                    watermark:
                        WorldwideIPhoneMicrophoneInboundMediaWatermark(
                            packetsReceived: inbound?.packets,
                            bytesReceived: inbound?.bytes,
                            jitterBufferEmittedCount:
                                inbound?.jitterBufferEmittedCount,
                            totalSamplesReceived:
                                inbound?.totalSamplesReceived
                        )
                )
            guard peer === sourcePeer,
                  peerGeneration == sourcePeerGeneration else {
                return
            }
            if let rtt = snapshot.currentRoundTripTime {
                logger.debug("Worldwide WebRTC RTT: \(Int((rtt * 1_000).rounded())) ms")
            }
            if let outbound = snapshot.outboundAudio {
                logger.debug(
                    "Worldwide audio RTP sentPackets="
                        + (outbound.packets.map { String($0) } ?? "unknown")
                        + " bytes=" + (outbound.bytes.map { String($0) } ?? "unknown")
                )
            }
            if let inbound {
                logger.debug(
                    Self.inboundAudioRTPLogMessage(
                        packets: inbound.packets,
                        bytes: inbound.bytes,
                        totalAudioEnergy: inbound.totalAudioEnergy,
                        audioLevel: inbound.audioLevel
                    )
                )
            }
            if let remoteInbound = snapshot.remoteInboundAudio {
                logger.debug(
                    "Worldwide audio remote loss="
                        + (remoteInbound.packetsLost.map { String($0) } ?? "unknown")
                        + " jitterMs="
                        + (remoteInbound.jitter.map {
                            String(format: "%.1f", $0 * 1_000)
                        } ?? "unknown")
                )
            }
            if let diagnostics = sourcePeer.externalAudioCapturer?.runtimeDiagnostics() {
                logger.debug(
                    "Worldwide audio queue phase=\(diagnostics.phase) "
                        + "frames=\(diagnostics.queuedFrames) "
                        + "high=\(diagnostics.queueHighWaterFrames) "
                        + "underruns=\(diagnostics.underruns) "
                        + "rebuffers=\(diagnostics.rebuffers) "
                        + "overflowDrops=\(diagnostics.overflowDrops) "
                        + "sourceGaps=\(diagnostics.sourceGaps) "
                        + "sourceOverlaps=\(diagnostics.sourceOverlaps)"
                )
            }
            let microphoneSnapshot =
                iPhoneMicrophoneForwarding.snapshot()
            logger.debug(
                Self.iPhoneMicrophoneForwardingLogMessage(
                    microphoneSnapshot
                )
            )
            if let selection = Self.hiddenWriterSelectionLogMessage(
                routingEpoch: blackHoleRoutingEpoch,
                peerGeneration:
                    microphoneSnapshot.peerGeneration,
                deviceGeneration:
                    microphoneSnapshot.deviceGeneration,
                selectionProven:
                    microphoneSnapshot.hiddenWriterSelectionProven,
                processIdentifier:
                    ProcessInfo.processInfo.processIdentifier
            ) {
                logger.info(selection)
            }
            await maintainWorldwideSafeOutputInvariant()

        case .iceCandidateError(let error):
            logger.error(
                "Worldwide ICE probe failed for \(error.url) " +
                "from \(error.address):\(error.port) [\(error.errorCode)]: \(error.reason)"
            )

        case .diagnosticFailure(let message):
            logger.error("Worldwide WebRTC diagnostic: \(message)")

        case .ended:
            await stop()

        case .remoteAudioTrack(let track):
            await installIPhoneMicrophoneTrack(track)

        case .identityReceived, .remoteVideoTrack, .negotiationNeeded:
            break
        }
    }

    // MARK: - Screen control protocol

    /// Linearizes Show, Hide, and key-frame requests with native capture state.
    ///
    /// Active is acknowledged only after capture and transport health are proven. Inactive
    /// is acknowledged only after native stop succeeds; every uncertainty path revokes media.
    private func handleControlRequest(_ request: WebRTCControlRequest) async {
        guard let peer else {
            _ = await stopScreenCaptureOrCloseSession(
                context: "a control request arrived without a peer"
            )
            return
        }

        if recoveryProofRequired,
           request.command != .hideScreen,
           let pendingRecoveryProofRequest,
           request.id > pendingRecoveryProofRequest.id {
            // WebRTCPeer only permits the highest received request to be acknowledged.
            // A later non-Hide therefore makes an older proof request unusable.
            self.pendingRecoveryProofRequest = nil
        }

        switch request.command {
        case .showScreen:
            do {
                guard transportAllowsCapture else {
                    throw WorldwideScreenServiceError.transportUnavailable
                }
                let authorization = try await startScreenCapture()
                guard let source = captureSource,
                      captureAuthorization === authorization,
                      authorization.isValid,
                      transportAllowsCapture else {
                    throw WorldwideScreenServiceError.transportUnavailable
                }
                let inputSession = armRemoteInputIfAvailable(
                    screenRequestID: request.id
                )
                let authorizationPeerGeneration = peerGeneration
                let authorizationRecoveryEpoch = recoveryProofEpoch
                // The viewer may say "Screen live" only after ScreenCaptureKit has actually
                // started. The revocable token linearizes recovery/capture-stop against the
                // final native-health check, track enable, and Active ACK send.
                try await peer.acknowledgeActiveControlRequestIfTransportHealthy(
                    id: request.id,
                    authorization: authorization,
                    inputCapability: inputSession?.capability,
                    inputAuthorization: inputSession?.authorization
                )
                let inputSessionRemainsCurrent: Bool
                if let inputSession {
                    inputSessionRemainsCurrent = activeInputCapability == inputSession.capability
                        && activeInputAuthorization === inputSession.authorization
                        && inputSession.authorization.isValid
                } else {
                    inputSessionRemainsCurrent = activeInputCapability == nil
                        && activeInputAuthorization == nil
                }
                guard authorizationPeerGeneration == peerGeneration,
                      authorizationRecoveryEpoch == recoveryProofEpoch,
                      self.peer === peer,
                      captureSource === source,
                      captureAuthorization === authorization,
                      authorization.isValid,
                      inputSessionRemainsCurrent,
                      transportAllowsCapture else {
                    // The Active transition linearized before a newer uncertainty boundary.
                    // Stop immediately and never send a contradictory ACK for the same ID.
                    _ = await stopScreenCaptureOrCloseSession(
                        context: "screen authorization changed during Active acknowledgement"
                    )
                    await peer.suspendScreenMediaForTransportUncertainty()
                    logger.error("Worldwide screen authorization changed during Active acknowledgement")
                    return
                }
            } catch {
                if isNativeScreenStopFailure(error) {
                    logger.error(
                        "Worldwide screen Show could not verify native capture shutdown: " +
                        error.localizedDescription
                    )
                    await stop()
                } else {
                    _ = await acknowledgeInactiveAfterVerifiedScreenStop(
                        peer: peer,
                        requestID: request.id,
                        context: "screen Show failed before Active acknowledgement"
                    )
                }
                logger.error("Worldwide screen Show failed closed: \(error.localizedDescription)")
            }

        case .hideScreen:
            if recoveryProofRequired {
                let proofRequest = PendingRecoveryProofRequest(
                    id: request.id,
                    epoch: recoveryProofEpoch
                )
                if pendingRecoveryProofRequest.map({ request.id > $0.id }) != false {
                    pendingRecoveryProofRequest = proofRequest
                }
                guard await stopScreenCaptureOrCloseSession(
                    context: "recovery-proof Hide"
                ) else {
                    return
                }
                await completePendingRecoveryProofIfPossible(
                    peer: peer,
                    epoch: proofRequest.epoch
                )
                return
            }

            _ = await acknowledgeInactiveAfterVerifiedScreenStop(
                peer: peer,
                requestID: request.id,
                context: "screen Hide"
            )

        case .requestKeyFrame:
            // RTP feedback remains WebRTC-owned; acknowledge the screen state without reusing a
            // VideoToolbox frame from the legacy path.
            if let source = captureSource,
               let authorization = captureAuthorization,
               authorization.isValid,
               transportAllowsCapture {
                let authorizationPeerGeneration = peerGeneration
                let authorizationRecoveryEpoch = recoveryProofEpoch
                do {
                    try await peer.acknowledgeControlRequestIfTransportHealthy(
                        id: request.id,
                        state: .active,
                        authorization: authorization
                    )
                    guard authorizationPeerGeneration == peerGeneration,
                          authorizationRecoveryEpoch == recoveryProofEpoch,
                          self.peer === peer,
                          captureSource === source,
                          captureAuthorization === authorization,
                          authorization.isValid,
                          transportAllowsCapture else {
                        _ = await stopScreenCaptureOrCloseSession(
                            context: "key-frame state changed during acknowledgement"
                        )
                        await peer.suspendScreenMediaForTransportUncertainty()
                        logger.error("Worldwide key-frame state changed during acknowledgement")
                        return
                    }
                } catch {
                    _ = await acknowledgeInactiveAfterVerifiedScreenStop(
                        peer: peer,
                        requestID: request.id,
                        context: "key-frame request failed before Active acknowledgement"
                    )
                    await peer.suspendScreenMediaForTransportUncertainty()
                    logger.error("Worldwide key-frame acknowledgement failed: \(error.localizedDescription)")
                }
            } else {
                do {
                    try await peer.acknowledgeControlRequest(
                        id: request.id,
                        state: .inactive
                    )
                } catch {
                    logger.error("Worldwide key-frame acknowledgement failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stops native screen capture before sending the matching Inactive acknowledgement.
    @discardableResult
    private func acknowledgeInactiveAfterVerifiedScreenStop(
        peer: WebRTCPeer,
        requestID: UInt64,
        context: String
    ) async -> Bool {
        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                try await self.stopScreenCapture()
            },
            acknowledgeInactive: {
                try await peer.acknowledgeControlRequest(
                    id: requestID,
                    state: .inactive
                )
            },
            failClosed: { error in
                self.logger.error(
                    "Worldwide native screen stop failed during \(context); " +
                    "closing the peer/session without an Inactive acknowledgement: " +
                    error.localizedDescription
                )
                await self.stop()
            }
        )

        guard let failure else { return true }
        switch failure {
        case .nativeStop:
            // The fail-closed closure has already closed the peer and rendezvous.
            return false
        case .acknowledgement(let error):
            logger.error(
                "Worldwide screen Inactive acknowledgement failed during \(context): " +
                error.localizedDescription
            )
            return false
        }
    }

    /// Stops capture or closes the whole session if native shutdown cannot be proven.
    @discardableResult
    private func stopScreenCaptureOrCloseSession(context: String) async -> Bool {
        do {
            try await stopScreenCapture()
            return true
        } catch {
            logger.error(
                "Worldwide native screen stop failed during \(context); " +
                "closing the peer/session: " + error.localizedDescription
            )
            await stop()
            return false
        }
    }

    /// Distinguishes native-stop uncertainty from ordinary Show startup failures.
    private func isNativeScreenStopFailure(_ error: any Error) -> Bool {
        guard let serviceError = error as? WorldwideScreenServiceError else {
            return false
        }
        if case .nativeScreenStopFailed = serviceError {
            return true
        }
        return false
    }

    // MARK: - Remote input

    /// Binds an input capability to the active display and exact Show request.
    private func armRemoteInputIfAvailable(
        screenRequestID: UInt64
    ) -> ArmedRemoteInputSession? {
        revokeRemoteInputAuthorization()
        guard let captureDisplayID else {
            return nil
        }

        let inputSessionID = UUID()
        switch remoteInputController.arm(
            displayID: captureDisplayID,
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) {
        case .armed:
            let capability = WebRTCInputCapability(
                inputSessionID: inputSessionID,
                screenRequestID: screenRequestID,
                supportsPrimaryDrag: true
            )
            let authorization = WebRTCInputAuthorization()
            activeInputCapability = capability
            activeInputAuthorization = authorization
            logger.info("Worldwide remote input is active for this screen session")
            return ArmedRemoteInputSession(
                capability: capability,
                authorization: authorization
            )

        case .disabled:
            return nil

        case .permissionRequired(let status):
            logger.info(
                "Worldwide remote input remains view-only; Accessibility trusted=" +
                "\(status.accessibilityTrusted), event posting allowed=\(status.postEventAllowed)"
            )
            return nil

        case .displayUnavailable:
            logger.error("Worldwide remote input could not bind the captured display")
            return nil
        }
    }

    /// Injects one request under revocable gates, then returns payload-free feedback.
    private func handleRemoteInputRequest(
        _ request: WebRTCInputRequest,
        authorization: WebRTCInputAuthorization
    ) async {
        guard let peer else {
            revokeRemoteInputAuthorization()
            return
        }

        // Keep both revocable gates held through controller validation and OS event injection.
        // The lock order is always input then capture. The first suspension is the feedback send
        // below, after the irreversible operation has either completed or been rejected.
        let inputResult = injectRemoteInputIfAuthorized(
            request,
            authorization: authorization
        )
        logger.debug(
            "Worldwide remote input \(diagnosticName(for: request.action)): " +
            diagnosticName(for: inputResult)
        )

        let feedback = transportFeedback(for: inputResult)
        if feedback.revokesSession {
            revokeRemoteInputAuthorization()
        }

        do {
            try await peer.sendInputFeedback(
                for: request.id,
                result: feedback.result,
                rejectionReason: feedback.rejectionReason,
                focus: feedback.focus
            )
        } catch {
            revokeRemoteInputAuthorization()
            // Never include action payloads or typed text in diagnostics.
            logger.error("Worldwide remote-input feedback failed: \(error.localizedDescription)")
        }
    }

    /// Holds input then capture authorization across the irreversible OS event post.
    private func injectRemoteInputIfAuthorized(
        _ request: WebRTCInputRequest,
        authorization: WebRTCInputAuthorization
    ) -> MacRemoteInputResult {
        guard let capability = activeInputCapability,
              let expectedInputAuthorization = activeInputAuthorization,
              expectedInputAuthorization === authorization,
              capability.screenRequestID == request.screenRequestID,
              capability.inputSessionID == request.inputSessionID,
              captureDisplayID != nil,
              captureSource != nil,
              let expectedCaptureAuthorization = captureAuthorization,
              transportAllowsCapture else {
            return .rejected(.staleSession)
        }
        if case .primaryDrag = request.action,
           !capability.supportsPrimaryDrag {
            return .rejected(.staleSession)
        }

        do {
            return try authorization.withValidAuthorization {
                try expectedCaptureAuthorization.withValidAuthorization {
                    guard activeInputAuthorization === authorization,
                          activeInputCapability == capability,
                          captureAuthorization === expectedCaptureAuthorization,
                          captureSource != nil,
                          captureDisplayID != nil,
                          transportAllowsCapture else {
                        return .rejected(.staleSession)
                    }
                    return injectRemoteInput(request)
                }
            }
        } catch {
            return .rejected(.staleSession)
        }
    }

    /// Maps validated wire actions onto the narrow macOS input controller surface.
    private func injectRemoteInput(_ request: WebRTCInputRequest) -> MacRemoteInputResult {
        switch request.action {
        case .tap(let point):
            remoteInputController.handleTap(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                normalizedPoint: .init(x: point.x, y: point.y)
            )

        case .primaryDrag(let start, let end):
            remoteInputController.handlePrimaryDrag(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                start: .init(x: start.x, y: start.y),
                end: .init(x: end.x, y: end.y)
            )

        case .insertText(let text, let focusGeneration):
            remoteInputController.insertText(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                focusGeneration: focusGeneration,
                text: text
            )

        case .backspace(let focusGeneration):
            remoteInputController.pressKey(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                focusGeneration: focusGeneration,
                key: .backspace
            )

        case .returnKey(let focusGeneration):
            remoteInputController.pressKey(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                focusGeneration: focusGeneration,
                key: .returnKey
            )
        }
    }

    /// Verbose acceptance diagnostics deliberately contain neither text payloads nor field data.
    private func diagnosticName(for action: WebRTCInputAction) -> String {
        switch action {
        case .tap:
            return "tap"
        case .primaryDrag:
            return "primary-drag"
        case .insertText:
            return "committed-text"
        case .backspace:
            return "backspace"
        case .returnKey:
            return "return"
        }
    }

    /// Reduces controller results to non-sensitive operational descriptions.
    private func diagnosticName(for result: MacRemoteInputResult) -> String {
        switch result {
        case .accepted(.none):
            return "accepted without editable focus"
        case .accepted(.editable):
            return "accepted with editable focus"
        case .rejected(let reason):
            return "rejected (\(reason))"
        }
    }

    /// Maps local outcomes to stable wire feedback and session-revocation policy.
    private func transportFeedback(
        for result: MacRemoteInputResult
    ) -> RemoteInputTransportFeedback {
        switch result {
        case .accepted(.none):
            return .accepted(focus: .none)
        case .accepted(.editable(let generation, let secure)):
            return .accepted(focus: .editable(generation: generation, secure: secure))

        case .rejected(let rejection):
            let reason: WebRTCInputRejectionReason
            let revokesSession: Bool
            switch rejection {
            case .disabled:
                reason = .inputDisabled
                revokesSession = true
            case .permissionRequired:
                let permission = remoteInputController.permissionStatus()
                reason = permission.accessibilityTrusted
                    ? .eventPostingPermissionRequired
                    : .accessibilityPermissionRequired
                revokesSession = true
            case .staleSession, .displayUnavailable:
                reason = .staleSession
                revokesSession = true
            case .invalidPoint, .invalidText:
                reason = .invalidRequest
                revokesSession = false
            case .rateLimited:
                reason = .rateLimited
                revokesSession = false
            case .focusChanged:
                reason = .invalidFocus
                revokesSession = false
            case .primaryButtonInUse, .injectionFailed:
                reason = .injectionFailed
                revokesSession = false
            }
            return .rejected(reason: reason, revokesSession: revokesSession)
        }
    }

    /// Revokes the transport token and controller state synchronously.
    private func revokeRemoteInputAuthorization() {
        activeInputAuthorization?.revoke()
        activeInputAuthorization = nil
        remoteInputController.revoke()
        activeInputCapability = nil
    }

    // MARK: - ICE recovery and proof

    /// Stops visible capture when the authenticated transport route becomes uncertain.
    private func stopScreenCaptureForTransportUncertainty(_ reason: String) async {
        guard captureSource != nil else { return }
        // Privacy is fail-closed: a recovered peer must receive a fresh, acknowledged Show.
        logger.info("Stopping worldwide screen capture because \(reason)")
        _ = await stopScreenCaptureOrCloseSession(
            context: "transport uncertainty: \(reason)"
        )
    }

    /// Revokes both media gates before asynchronously stopping their native sources.
    private func stopCaptureForTransportUncertainty(_ reason: String) async {
        // Revoke both media gates before either asynchronous ScreenCaptureKit stop begins.
        revokeCaptureAuthorization()
        pauseSystemAudioForTransportUncertainty()
        captureSink?.stopForwarding()
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput
                .transportDidBecomeUnhealthy(
                    peerGeneration: peerGeneration
                )
        )
        iPhoneMicrophoneForwarding.invalidateTransport()
        await peer?.suspendSystemAudioForTransportUncertainty()
        await stopScreenCaptureForTransportUncertainty(reason)
        await stopSystemAudioForTransportUncertainty(reason)
    }

    /// Installs a new proof epoch, removes media, then requests native ICE restart.
    private func beginICERestart(
        peer: WebRTCPeer,
        peerGeneration generation: UInt64
    ) async throws {
        guard generation == peerGeneration, !isStopped, self.peer != nil else {
            throw CancellationError()
        }
        let epoch = installRecoveryProofBoundary(awaitingAnswer: true)
        await stopCaptureForTransportUncertainty("an ICE restart began")
        guard generation == peerGeneration,
              epoch == recoveryProofEpoch,
              !isStopped,
              self.peer === peer else {
            throw CancellationError()
        }
        do {
            try await peer.restartICE()
        } catch {
            if epoch == recoveryProofEpoch,
               restartAnswerAwaitingEpoch == epoch {
                restartAnswerAwaitingEpoch = nil
            }
            throw error
        }
    }

    /// Enters fail-closed recovery and invalidates any pre-uncertainty authorization.
    private func enterRecovery(reason: String) async {
        isRecovering = true
        revokeCaptureAuthorization()
        pauseSystemAudioForTransportUncertainty()
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput
                .transportDidBecomeUnhealthy(
                    peerGeneration: peerGeneration
                )
        )
        iPhoneMicrophoneForwarding.invalidateTransport()
        if recoveryProofRequired {
            // Invalidate a pre-uncertainty Hide/ACK without severing the current offer→answer
            // epoch. Native disconnected events are expected during an in-flight restart.
            recoveryProofAuthorization?.revoke()
            recoveryProofAuthorization = WebRTCControlAuthorization()
            pendingRecoveryProofRequest = nil
            recoveryProofAcknowledgementInFlight = nil
        }
        await stopCaptureForTransportUncertainty(reason)
    }

    /// Creates a fresh epoch that requires answer installation plus a Hide/Inactive proof.
    @discardableResult
    private func installRecoveryProofBoundary(awaitingAnswer: Bool) -> UInt64 {
        revokeCaptureAuthorization()
        pauseSystemAudioForTransportUncertainty()
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput
                .transportDidBecomeUnhealthy(
                    peerGeneration: peerGeneration
                )
        )
        iPhoneMicrophoneForwarding.invalidateTransport()
        recoveryProofAuthorization?.revoke()
        recoveryProofEpoch &+= 1
        let epoch = recoveryProofEpoch
        recoveryProofRequired = true
        isRecovering = true
        restartAnswerAwaitingEpoch = awaitingAnswer ? epoch : nil
        restartAnswerAppliedEpoch = nil
        pendingRecoveryProofRequest = nil
        recoveryProofAcknowledgementInFlight = nil
        recoveryProofAuthorization = WebRTCControlAuthorization()
        return epoch
    }

    /// Completes recovery only when transport, restart answer, and proof request agree on epoch.
    private func completePendingRecoveryProofIfPossible(
        peer: WebRTCPeer,
        epoch: UInt64
    ) async {
        guard !isStopped,
              self.peer === peer,
              recoveryProofRequired,
              epoch == recoveryProofEpoch,
              restartAnswerAppliedEpoch == epoch,
              let request = pendingRecoveryProofRequest,
              request.epoch == epoch,
              recoveryProofAcknowledgementInFlight == nil,
              let authorization = recoveryProofAuthorization,
              authorization.isValid else {
            return
        }

        recoveryProofAcknowledgementInFlight = request
        do {
            try await peer.acknowledgeControlRequestIfTransportHealthy(
                id: request.id,
                state: .inactive,
                authorization: authorization
            )
        } catch {
            if recoveryProofAcknowledgementInFlight == request {
                recoveryProofAcknowledgementInFlight = nil
            }
            if let transportError = error as? WebRTCTransportError,
               transportError == .transportNotHealthy
                    || transportError == .controlAuthorizationRevoked {
                return
            }
            logger.error("Worldwide recovery proof acknowledgement failed: \(error.localizedDescription)")
            return
        }

        guard recoveryProofAcknowledgementInFlight == request else { return }
        recoveryProofAcknowledgementInFlight = nil
        guard !isStopped,
              self.peer === peer,
              recoveryProofRequired,
              epoch == recoveryProofEpoch,
              restartAnswerAppliedEpoch == epoch,
              pendingRecoveryProofRequest == request,
              recoveryProofAuthorization === authorization,
              authorization.isValid else {
            return
        }

        authorization.revoke()
        recoveryProofAuthorization = nil
        pendingRecoveryProofRequest = nil
        restartAnswerAwaitingEpoch = nil
        restartAnswerAppliedEpoch = nil
        recoveryProofRequired = false
        isRecovering = false
        let routingAdmission =
            admitBlackHoleInputWithinSafeOutputFence()
        let outputsAreSafe = routingAdmission.outputsAreSafe
        let currentBlackHoleSnapshot = routingAdmission.snapshot
        guard await startSystemAudioOrStopSession() else {
            await recoverFromSystemAudioStartUncertainty(
                "system audio could not be enabled after route proof"
            )
            return
        }
        if outputsAreSafe,
           let currentBlackHoleSnapshot {
            await iPhoneMicrophoneForwarding.updateDeviceSnapshot(
                currentBlackHoleSnapshot
            )
            await authorizeIPhoneMicrophoneForwardingIfPossible()
        }
        await recoveryCoordinator?.iceStateChanged(.connected)
    }

    /// Marks an initially healthy route usable and ensures system audio is live.
    @discardableResult
    private func markRecoveryHealthyIfPossible() async -> Bool {
        guard !recoveryProofRequired,
              peerIsConnected,
              iceIsConnected,
              controlChannelIsOpen else {
            return false
        }
        isRecovering = false
        let routingAdmission =
            admitBlackHoleInputWithinSafeOutputFence()
        let outputsAreSafe = routingAdmission.outputsAreSafe
        let currentBlackHoleSnapshot = routingAdmission.snapshot
        guard await startSystemAudioOrStopSession() else {
            await recoverFromSystemAudioStartUncertainty(
                "system audio could not be enabled on the healthy route"
            )
            return false
        }
        if outputsAreSafe,
           let currentBlackHoleSnapshot {
            await iPhoneMicrophoneForwarding.updateDeviceSnapshot(
                currentBlackHoleSnapshot
            )
            await authorizeIPhoneMicrophoneForwardingIfPossible()
        }
        return true
    }

    // MARK: - iPhone microphone to BlackHole

    /// Keeps the exact output listeners registered through input-only admission.
    /// LAN coexistence retains its legacy policy and never reaches this ownership path.
    private func admitBlackHoleInputWithinSafeOutputFence()
        -> (
            outputsAreSafe: Bool,
            snapshot: BlackHoleDeviceAvailabilitySnapshot?
        ) {
        guard iPhoneMicrophoneForwardingPolicy == .enabled else {
            safeOutputInvariantNeedsRedrive = false
            safeOutputInvariantVerificationWasFailing = false
            safeOutputInvariantRetryPolicy.reset()
            return (false, nil)
        }
        guard transportAllowsCapture else {
            return (false, nil)
        }
        guard let monitoringEpoch =
                safeOutputInvariantMonitoringEpoch,
              let authorizationGate =
                blackHoleMicrophoneOutputAuthorizationGate else {
            return (false, nil)
        }
        if sharedClockBlocksCurrentPeerAndPair() {
            authorizationGate.close()
            return (false, nil)
        }
        if formatUnsafeBlocksCurrentPeerAndPair() {
            authorizationGate.close()
            return (false, nil)
        }
        if safeOutputInvariantNeedsRedrive,
           !safeOutputInvariantRetryPolicy
            .shouldAttemptOnCurrentTick() {
            return (false, nil)
        }

        var admittedOutcomes:
            [WorldwideBlackHoleDefaultInputOutcome] = []
        var defaultInputAdmissionSucceeded = false
        var admittedDefaultInputAuthorization:
            BlackHoleDefaultInputLeaseAuthorization?
        var preMutationOutcome:
            WorldwideBlackHoleDefaultInputOutcome?
        var rollbackOutcome:
            WorldwideBlackHoleDefaultInputOutcome?
        var gateOpeningPreparation:
            BlackHoleMicrophoneOutputAuthorizationGate
                .OpeningPreparation?
        do {
            let transaction = try worldwideSafeOutputInvariant
                .enforceDuringAdmission(
                    monitoringEpoch: monitoringEpoch,
                    beforeFirstMutation: {
                        authorizationGate.close()
                        self.safeOutputInvariantAuthorization = nil
                        self.blackHoleEndpointPairAuthorization = nil
                        self.blackHoleDefaultInputAuthorization = nil
                        self.iPhoneMicrophoneForwarding
                            .invalidateTransport()
                        let outcome =
                            self.blackHoleDefaultInput
                                .transportDidBecomeUnhealthy(
                                    peerGeneration:
                                        self.peerGeneration
                                )
                        preMutationOutcome = outcome
                        if outcome == .degraded {
                            throw WorldwideScreenServiceError
                                .microphoneInputReleaseUnproved
                        }
                    },
                    admission: { ()
                        -> BlackHoleDeviceAvailabilitySnapshot? in
                        // First acquire under a fresh atomic-pair validation.
                        // Its owned default-input write produces the exact
                        // listener event that the lease incorporates below.
                        guard let initialRevalidation =
                                self.revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()
                        else {
                            return nil
                        }
                        admittedOutcomes.append(
                            initialRevalidation.outcome
                        )
                        let initialOutcome = self.blackHoleDefaultInput
                            .transportDidBecomeHealthy(
                                peerGeneration:
                                    self.peerGeneration
                            )
                        admittedOutcomes.append(initialOutcome)
                        guard case .selected = initialOutcome else {
                            return nil
                        }

                        // Prepare only after the lease's owned notification has
                        // been consumed. Then span a final pair validation and
                        // exact input-listener proof. Any later device, output,
                        // or input callback closes this generation and prevents
                        // commit from reopening stale routing.
                        gateOpeningPreparation =
                            authorizationGate.prepareToOpen()
                        guard let finalRevalidation =
                                self.revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()
                        else {
                            return nil
                        }
                        admittedOutcomes.append(
                            finalRevalidation.outcome
                        )
                        let finalOutcome = self.blackHoleDefaultInput
                            .transportDidBecomeHealthy(
                                peerGeneration:
                                    self.peerGeneration
                            )
                        admittedOutcomes.append(finalOutcome)
                        switch finalOutcome {
                        case .selected(let key)
                            where key.monitorEpoch
                                == finalRevalidation.snapshot.monitorEpoch
                                && key.deviceGeneration
                                    == finalRevalidation.snapshot.deviceGeneration
                                && key.peerGeneration == self.peerGeneration
                                && key.deviceEndpoint
                                    == finalRevalidation.snapshot.defaultInputEndpoint
                                && key.inputAuthorization.targetEndpoint
                                    == finalRevalidation.snapshot.defaultInputEndpoint:
                            admittedDefaultInputAuthorization =
                                key.inputAuthorization
                            defaultInputAdmissionSucceeded = true

                        case .selected, .noChange,
                             .waitingForMonitor, .waitingForDevice,
                             .released, .degraded, .suppressed:
                            defaultInputAdmissionSucceeded = false
                        }
                        return finalRevalidation.snapshot
                    },
                    rollback: { _ in
                        authorizationGate.close()
                        self.safeOutputInvariantAuthorization = nil
                        self.blackHoleEndpointPairAuthorization = nil
                        self.blackHoleDefaultInputAuthorization = nil
                        self.iPhoneMicrophoneForwarding
                            .invalidateTransport()
                        rollbackOutcome =
                            self.blackHoleDefaultInput
                                .transportDidBecomeUnhealthy(
                                    peerGeneration:
                                        self.peerGeneration
                                )
                    },
                    commit: { admittedSnapshot, authorization in
                        guard let admittedSnapshot,
                              admittedSnapshot.isAvailable,
                              defaultInputAdmissionSucceeded,
                              let admittedDefaultInputAuthorization,
                              admittedDefaultInputAuthorization.targetEndpoint
                                == admittedSnapshot.defaultInputEndpoint else {
                            throw WorldwideScreenServiceError
                                .microphoneInputAdmissionUnavailable
                        }
                        guard let gateOpeningPreparation else {
                            throw WorldwideScreenServiceError
                                .microphoneWriterAuthorizationSuperseded
                        }
                        guard authorizationGate.open(
                            preparation: gateOpeningPreparation,
                            authorization: authorization
                        ) else {
                            throw WorldwideScreenServiceError
                                .microphoneWriterAuthorizationSuperseded
                        }
                        self.safeOutputInvariantAuthorization =
                            authorization
                        self.blackHoleDefaultInputAuthorization =
                            admittedDefaultInputAuthorization
                        self.blackHoleEndpointPairAuthorization =
                            BlackHoleEndpointPairAuthorization(
                                monitorEpoch:
                                    admittedSnapshot.monitorEpoch,
                                deviceGeneration:
                                    admittedSnapshot.deviceGeneration,
                                acceptedInventoryChangeSequence:
                                    admittedSnapshot
                                        .acceptedInventoryChangeSequence
                            )
                    }
                )
            safeOutputInvariantNeedsRedrive = false
            safeOutputInvariantVerificationWasFailing = false
            safeOutputInvariantRetryPolicy.reset()
            if transaction.invariant.changedAnything {
                logger.info(
                    "Worldwide audio routing moved the virtual microphone off the " +
                        "default output selectors before selecting it " +
                        "as the iPhone microphone input"
                )
            }
            if let preMutationOutcome {
                recordBlackHoleDefaultInputOutcome(
                    preMutationOutcome
                )
            }
            for outcome in admittedOutcomes {
                recordBlackHoleDefaultInputOutcome(outcome)
            }
            return (true, transaction.admission)
        } catch {
            authorizationGate.close()
            safeOutputInvariantAuthorization = nil
            blackHoleEndpointPairAuthorization = nil
            blackHoleDefaultInputAuthorization = nil
            iPhoneMicrophoneForwarding.invalidateTransport()
            if let preMutationOutcome {
                recordBlackHoleDefaultInputOutcome(
                    preMutationOutcome
                )
            }
            if let rollbackOutcome {
                recordBlackHoleDefaultInputOutcome(
                    rollbackOutcome
                )
            } else {
                recordBlackHoleDefaultInputOutcome(
                    blackHoleDefaultInput
                        .transportDidBecomeUnhealthy(
                            peerGeneration: peerGeneration
                        )
                )
            }
            safeOutputInvariantNeedsRedrive = true
            safeOutputInvariantRetryPolicy.recordFailure()
            logger.error(
                "Worldwide iPhone microphone routing remains disabled " +
                    "because the safe-output invariant could not be " +
                    "proven: " + error.localizedDescription
            )
            return (false, nil)
        }
    }

    /// Continuously verifies the output invariant. Any unsafe or unprovable route
    /// synchronously revokes microphone admission and default-input ownership before
    /// a capped, backed-off mutation attempt can run.
    private func maintainWorldwideSafeOutputInvariant() async {
        guard iPhoneMicrophoneForwardingPolicy == .enabled,
              transportAllowsCapture else {
            return
        }
        guard let monitoringEpoch =
                safeOutputInvariantMonitoringEpoch else {
            safeOutputInvariantNeedsRedrive = true
            revokeWorldwideMicrophoneForUnsafeOutputInvariant()
            return
        }

        let verification:
            WorldwideSafeOutputInvariantVerification
        do {
            verification = try worldwideSafeOutputInvariant.verify(
                monitoringEpoch: monitoringEpoch
            )
        } catch {
            let wasVerificationFailing =
                safeOutputInvariantVerificationWasFailing
            safeOutputInvariantVerificationWasFailing = true
            safeOutputInvariantNeedsRedrive = true
            revokeWorldwideMicrophoneForUnsafeOutputInvariant()
            if !wasVerificationFailing {
                logger.error(
                    "Worldwide microphone routing was revoked because " +
                        "the safe-output invariant could not be verified: " +
                        error.localizedDescription
                )
            }
            return
        }

        if safeOutputInvariantVerificationWasFailing {
            safeOutputInvariantVerificationWasFailing = false
            safeOutputInvariantRetryPolicy.reset()
        }

        if verification.isSatisfied {
            safeOutputInvariantRetryPolicy.reset()
            guard safeOutputInvariantNeedsRedrive else {
                return
            }
            safeOutputInvariantNeedsRedrive = false
            await resumeWorldwideMicrophoneAfterSafeOutputInvariant()
            return
        }

        if verification.changedSincePreviousObservation {
            safeOutputInvariantRetryPolicy.reset()
        }
        safeOutputInvariantNeedsRedrive = true
        revokeWorldwideMicrophoneForUnsafeOutputInvariant()
        await resumeWorldwideMicrophoneAfterSafeOutputInvariant()
    }

    /// A selector callback has already closed the lock-free writer gate before
    /// this actor work is queued. Discard only events superseded by an exact
    /// listener-sequence authorization; every newer event revokes ownership
    /// before any repair or suspension point.
    private func safeOutputInvariantDidBecomeUncertain(
        epoch: WorldwideSafeOutputInvariantMonitoringEpoch,
        eventSequence: UInt64
    ) async {
        guard !isStopped,
              safeOutputInvariantMonitoringEpoch == epoch else {
            return
        }
        if let authorization = safeOutputInvariantAuthorization,
           authorization.monitoringEpoch == epoch,
           eventSequence <= authorization.listenerSequence {
            return
        }

        safeOutputInvariantAuthorization = nil
        blackHoleEndpointPairAuthorization = nil
        blackHoleDefaultInputAuthorization = nil
        safeOutputInvariantNeedsRedrive = true
        safeOutputInvariantRetryPolicy.reset()
        revokeWorldwideMicrophoneForUnsafeOutputInvariant()
        await resumeWorldwideMicrophoneAfterSafeOutputInvariant()
    }

    private func revokeWorldwideMicrophoneForUnsafeOutputInvariant() {
        revokeWorldwideMicrophoneForUnsafeOutputInvariant(
            preservingSharedClockUnsafeFailure: false,
            preservingFormatUnsafeFailure: false
        )
    }

    private func revokeWorldwideMicrophoneForUnsafeOutputInvariant(
        preservingSharedClockUnsafeFailure: Bool,
        preservingFormatUnsafeFailure: Bool = false
    ) {
        blackHoleMicrophoneOutputAuthorizationGate?.close()
        safeOutputInvariantAuthorization = nil
        blackHoleEndpointPairAuthorization = nil
        blackHoleDefaultInputAuthorization = nil
        iPhoneMicrophoneForwarding.invalidateTransport(
            preservingSharedClockUnsafeFailure:
                preservingSharedClockUnsafeFailure,
            preservingFormatUnsafeFailure:
                preservingFormatUnsafeFailure
        )
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput.transportDidBecomeUnhealthy(
                peerGeneration: peerGeneration
            )
        )
    }

    private func resumeWorldwideMicrophoneAfterSafeOutputInvariant()
        async {
        guard transportAllowsCapture else { return }
        let routingAdmission =
            admitBlackHoleInputWithinSafeOutputFence()
        guard routingAdmission.outputsAreSafe else { return }
        let currentBlackHoleSnapshot = routingAdmission.snapshot
        if let currentBlackHoleSnapshot {
            await iPhoneMicrophoneForwarding.updateDeviceSnapshot(
                currentBlackHoleSnapshot
            )
            await authorizeIPhoneMicrophoneForwardingIfPossible()
        }
    }

    /// Holds the captured clock rejection across statistics ticks and transport
    /// epochs. A genuinely new peer or atomic endpoint-pair generation is the
    /// only automatic retry boundary for this deterministic incompatibility.
    private func sharedClockBlocksCurrentPeerAndPair() -> Bool {
        Self.sharedClockBlockRemainsActive(
            &sharedClockBlockedPeerPair,
            peerGeneration: peerGeneration,
            snapshot:
                blackHoleDeviceAvailabilityMonitor.currentSnapshot()
        )
    }

    nonisolated static func sharedClockBlockRemainsActive(
        _ blockedPeerPair: inout SharedClockBlockedPeerPair?,
        peerGeneration: UInt64,
        snapshot: BlackHoleDeviceAvailabilitySnapshot?
    ) -> Bool {
        guard let blocked = blockedPeerPair else {
            return false
        }
        guard blocked.peerGeneration == peerGeneration else {
            blockedPeerPair = nil
            return false
        }
        guard let snapshot else {
            return true
        }
        guard blocked.matches(
            peerGeneration: peerGeneration,
            snapshot: snapshot
        ) else {
            blockedPeerPair = nil
            return false
        }
        return true
    }

    /// A format/readback rejection is deterministic for the captured output
    /// pair. Keep that exact peer/pair fenced until either generation changes.
    private func formatUnsafeBlocksCurrentPeerAndPair() -> Bool {
        Self.formatUnsafeBlockRemainsActive(
            &formatUnsafeBlockedPeerPair,
            peerGeneration: peerGeneration,
            snapshot:
                blackHoleDeviceAvailabilityMonitor.currentSnapshot()
        )
    }

    nonisolated static func formatUnsafeBlockRemainsActive(
        _ blockedPeerPair: inout FormatUnsafeBlockedPeerPair?,
        peerGeneration: UInt64,
        snapshot: BlackHoleDeviceAvailabilitySnapshot?
    ) -> Bool {
        guard let blocked = blockedPeerPair else {
            return false
        }
        guard blocked.peerGeneration == peerGeneration else {
            blockedPeerPair = nil
            return false
        }
        guard let snapshot else {
            return true
        }
        guard blocked.matches(
            peerGeneration: peerGeneration,
            snapshot: snapshot
        ) else {
            blockedPeerPair = nil
            return false
        }
        return true
    }

    private func iPhoneMicrophoneSharedClockDidFail(
        key: WorldwideIPhoneMicrophoneForwardingKey,
        rejection: BlackHoleFaceTimeClockRejection
    ) {
        guard key.peerGeneration == peerGeneration else {
            return
        }
        if let snapshot =
                blackHoleDeviceAvailabilityMonitor.currentSnapshot() {
            guard snapshot.monitorEpoch == key.monitorEpoch,
                  snapshot.deviceGeneration
                    == key.deviceGeneration else {
                return
            }
        }

        sharedClockBlockedPeerPair =
            SharedClockBlockedPeerPair(forwardingKey: key)
        revokeWorldwideMicrophoneForUnsafeOutputInvariant(
            preservingSharedClockUnsafeFailure: true
        )
        logger.error(
            Self.iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .sharedClockUnsafe(rejection)
            )
        )
    }

    private func iPhoneMicrophoneFormatDidFail(
        key: WorldwideIPhoneMicrophoneForwardingKey,
        rejection: BlackHoleMicrophoneOutputFormatRejection
    ) {
        guard key.peerGeneration == peerGeneration else {
            return
        }
        if let snapshot =
                blackHoleDeviceAvailabilityMonitor.currentSnapshot() {
            guard snapshot.monitorEpoch == key.monitorEpoch,
                  snapshot.deviceGeneration
                    == key.deviceGeneration else {
                return
            }
        }

        formatUnsafeBlockedPeerPair =
            FormatUnsafeBlockedPeerPair(forwardingKey: key)
        revokeWorldwideMicrophoneForUnsafeOutputInvariant(
            preservingSharedClockUnsafeFailure: false,
            preservingFormatUnsafeFailure: true
        )
        logger.error(
            Self.iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .formatUnsafe(rejection)
            )
        )
    }

    private func startIPhoneMicrophoneDeviceMonitoringIfNeeded()
        async {
        guard iPhoneMicrophoneForwardingPolicy == .enabled else {
            return
        }

        guard WorldwideBlackHoleAudioRoutingStartupGate
            .redriveAndPermitNewOwnership(
                retainer:
                    WorldwideBlackHoleAudioRoutingCleanupRetainer
                        .shared,
                maximumAttemptCount: 1
            ) else {
            blackHoleDeviceMonitorEpoch = nil
            logger.error(
                "Virtual microphone device monitoring startup is deferred " +
                    "because an older lease or service still retains unresolved " +
                    "exact Core Audio routing cleanup ownership"
            )
            return
        }

        guard let authorizationGate =
                blackHoleMicrophoneOutputAuthorizationGate else {
            logger.error(
                "Virtual microphone writer authorization is unavailable; " +
                    "automatic input selection and forwarding remain disabled"
            )
            return
        }

        blackHoleDefaultInputLease.setUncertaintyHandler {
            [weak self, authorizationGate] event in
            // This is the raw default-input selector callback. Close the
            // realtime writer before the lease or actor can reconcile it.
            authorizationGate.close()
            Task { [weak self] in
                await self?
                    .blackHoleDefaultInputDidBecomeUncertain(event)
            }
        }

        do {
            safeOutputInvariantMonitoringEpoch =
                try worldwideSafeOutputInvariant
                    .beginSessionMonitoring {
                        [weak self, authorizationGate]
                        epoch,
                        eventSequence in
                        authorizationGate.close()
                        Task { [weak self] in
                            await self?
                                .safeOutputInvariantDidBecomeUncertain(
                                    epoch: epoch,
                                    eventSequence: eventSequence
                                )
                        }
                    }
        } catch {
            safeOutputInvariantMonitoringEpoch = nil
            authorizationGate.close()
            logger.error(
                "Safe-output session monitoring is unavailable; " +
                    "automatic input selection and forwarding remain " +
                    "disabled: " + error.localizedDescription
            )
            return
        }

        do {
            let epoch = try blackHoleDeviceAvailabilityMonitor.start(
                onUncertain: {
                    [weak self, authorizationGate]
                    monitorEpoch,
                    eventSequence in
                    // This is the raw Core Audio callback boundary. Close
                    // synchronously before the monitor dispatches refresh or
                    // either reconciliation Task can reach this actor.
                    authorizationGate.close()
                    Task { [weak self] in
                        await self?
                            .blackHoleDeviceInventoryDidBecomeUncertain(
                                monitorEpoch: monitorEpoch,
                                eventSequence: eventSequence
                            )
                    }
                },
                observer: { [weak self] snapshot in
                    Task { [weak self] in
                        await self?.blackHoleDeviceAvailabilityDidChange(
                            snapshot
                        )
                    }
                }
            )
            blackHoleDeviceMonitorEpoch = epoch
            _ = blackHoleDefaultInput.beginMonitoring(
                epoch: epoch
            )
            iPhoneMicrophoneForwarding.beginMonitoring(
                epoch: epoch
            )
            await consumeCurrentBlackHoleDeviceSnapshot()
        } catch {
            blackHoleDeviceMonitorEpoch = nil
            endSafeOutputInvariantMonitoring()
            recordBlackHoleDefaultInputOutcome(
                blackHoleDefaultInput.monitoringDidFail()
            )
            iPhoneMicrophoneForwarding.monitoringDidFail()
            logger.error(
                "Virtual microphone device monitoring is unavailable; " +
                    "iPhone microphone forwarding remains disabled: " +
                    error.localizedDescription
            )
        }
    }

    private func consumeCurrentBlackHoleDeviceSnapshot()
        async {
        let snapshot: BlackHoleDeviceAvailabilitySnapshot?
        if transportAllowsCapture {
            snapshot =
                admitBlackHoleInputWithinSafeOutputFence().snapshot
        } else {
            snapshot =
                consumeCurrentBlackHoleDeviceSnapshotForDefaultInput()
        }
        guard let snapshot else {
            return
        }
        await iPhoneMicrophoneForwarding.updateDeviceSnapshot(
            snapshot
        )
        if transportAllowsCapture {
            await authorizeIPhoneMicrophoneForwardingIfPossible()
        }
    }

    private struct RevalidatedBlackHoleDeviceSnapshot {
        let snapshot: BlackHoleDeviceAvailabilitySnapshot
        let outcome: WorldwideBlackHoleDefaultInputOutcome
    }

    @discardableResult
    private func consumeCurrentBlackHoleDeviceSnapshotForDefaultInput()
        -> BlackHoleDeviceAvailabilitySnapshot? {
        guard let revalidated =
                revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()
        else {
            return nil
        }
        recordBlackHoleDefaultInputOutcome(
            revalidated.outcome
        )
        return revalidated.snapshot
    }

    private func revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()
        -> RevalidatedBlackHoleDeviceSnapshot? {
        guard !isStopped else { return nil }
        switch blackHoleDeviceAvailabilityMonitor
            .revalidateCurrentSnapshot() {
        case .validated(let snapshot):
            guard snapshot.monitorEpoch
                    == blackHoleDeviceMonitorEpoch else {
                return nil
            }
            return RevalidatedBlackHoleDeviceSnapshot(
                snapshot: snapshot,
                outcome: blackHoleDefaultInput
                    .updateDeviceSnapshot(snapshot)
            )

        case .validationFailed, .inactive:
            recordBlackHoleDefaultInputOutcome(
                blackHoleDefaultInput
                    .deviceRevalidationDidFail()
            )
            iPhoneMicrophoneForwarding.monitoringDidFail()
            logger.error(
                "Virtual microphone endpoint-pair revalidation failed; " +
                    "automatic input selection and iPhone microphone " +
                    "forwarding were revoked"
            )
            return nil
        }
    }

    private func blackHoleDeviceAvailabilityDidChange(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) async {
        guard !isStopped,
              snapshot.monitorEpoch == blackHoleDeviceMonitorEpoch else {
            return
        }
        // The observer crosses into this actor through an unsequenced Task.
        // Never admit its captured snapshot directly: a newer synchronous
        // validation failure may already have revoked that same generation.
        // Re-read the exact pair so only fresh evidence can restore routing.
        if safeOutputInvariantNeedsRedrive {
            safeOutputInvariantRetryPolicy.reset()
        }
        await consumeCurrentBlackHoleDeviceSnapshot()
    }

    /// The raw callback has already closed the lock-free writer gate. If a
    /// same-event revalidation committed while this Task waited for the actor,
    /// its exact sequence supersedes this reconciliation. A newer event always
    /// revokes the pair proof and must complete a fresh admission.
    private func blackHoleDeviceInventoryDidBecomeUncertain(
        monitorEpoch: UUID,
        eventSequence: UInt64
    ) async {
        guard !isStopped,
              blackHoleDeviceMonitorEpoch == monitorEpoch else {
            return
        }
        if let authorization = blackHoleEndpointPairAuthorization,
           authorization.monitorEpoch == monitorEpoch,
           eventSequence
                <= authorization.acceptedInventoryChangeSequence {
            return
        }

        blackHoleEndpointPairAuthorization = nil
        blackHoleDefaultInputAuthorization = nil
        safeOutputInvariantNeedsRedrive = true
        safeOutputInvariantRetryPolicy.reset()
        revokeWorldwideMicrophoneForUnsafeOutputInvariant()
        await resumeWorldwideMicrophoneAfterSafeOutputInvariant()
    }

    /// The exact default-input listener already closed the writer gate at the
    /// raw callback boundary. Drop only the callback included by the admission
    /// proof that reopened it. A newer or mismatched event is an external choice:
    /// stop forwarding, relinquish ownership without restoration, and leave this
    /// connection terminal instead of automatically selecting over the user.
    private func blackHoleDefaultInputDidBecomeUncertain(
        _ event: BlackHoleDefaultInputLeaseUncertaintyEvent
    ) async {
        guard !isStopped else { return }
        if let authorization = blackHoleDefaultInputAuthorization,
           authorization.incorporates(event) {
            return
        }

        blackHoleDefaultInputAuthorization = nil
        blackHoleEndpointPairAuthorization = nil
        iPhoneMicrophoneForwarding.invalidateTransport()
        recordBlackHoleDefaultInputOutcome(
            blackHoleDefaultInput
                .defaultInputDidBecomeUncertain(event)
        )
    }

    func iPhoneMicrophoneForwardingSnapshot()
        -> WorldwideIPhoneMicrophoneForwardingHostSnapshot {
        iPhoneMicrophoneForwarding.snapshot()
    }

    private func authorizeIPhoneMicrophoneForwardingIfPossible()
        async {
        guard transportAllowsCapture,
              let peer else {
            return
        }
        await iPhoneMicrophoneForwarding.authorizeTransport(
            peer: peer,
            peerGeneration: peerGeneration
        )
    }

    private func shutdownBlackHoleAudioRouting() {
        blackHoleMicrophoneOutputAuthorizationGate?.close()
        safeOutputInvariantAuthorization = nil
        blackHoleEndpointPairAuthorization = nil
        blackHoleDefaultInputAuthorization = nil
        let safeOutputMonitoringEpoch =
            safeOutputInvariantMonitoringEpoch
        safeOutputInvariantMonitoringEpoch = nil
        blackHoleDeviceMonitorEpoch = nil

        let result =
            WorldwideBlackHoleAudioRoutingCleanupPolicy.run(
                maximumEpisodeCount:
                    maximumBlackHoleAudioRoutingCleanupEpisodeCount,
                shutdownDefaultInput: {
                    self.blackHoleDefaultInput.shutdown()
                },
                stopDeviceMonitor: {
                    self.blackHoleDeviceAvailabilityMonitor
                        .stop()
                }
            )

        if result == .degraded {
            let lease = blackHoleDefaultInputLease
            let monitor =
                blackHoleDeviceAvailabilityMonitor
            let invariant = worldwideSafeOutputInvariant
            WorldwideBlackHoleAudioRoutingCleanupRetainer
                .shared
                .retain(
                    id: blackHoleAudioRoutingCleanupID
                ) {
                    let defaultInputCompleted =
                        lease.shutdown()
                            != .retryableFailure
                    let monitorCompleted =
                        monitor.stop() == .stopped
                    guard defaultInputCompleted,
                          monitorCompleted else {
                        return false
                    }
                    if let safeOutputMonitoringEpoch {
                        // The writer gate was closed before this retained
                        // cleanup began. Listener-removal failure is itself
                        // retained by the invariant with the exact identities.
                        try? invariant.endSessionMonitoring(
                            epoch: safeOutputMonitoringEpoch
                        )
                    }
                    return true
                }
            logger.error(
                "Virtual microphone audio-routing cleanup remains degraded " +
                    "after its single globally bounded shutdown " +
                    "episode; exact Core Audio cleanup ownership " +
                    "is retained for a later explicit lifecycle redrive"
            )
        } else {
            if let safeOutputMonitoringEpoch {
                do {
                    try worldwideSafeOutputInvariant
                        .endSessionMonitoring(
                            epoch: safeOutputMonitoringEpoch
                        )
                } catch {
                    logger.error(
                        "Safe-output listener cleanup remains degraded: " +
                            error.localizedDescription
                    )
                }
            }
            WorldwideBlackHoleAudioRoutingCleanupRetainer
                .shared
                .remove(
                    id: blackHoleAudioRoutingCleanupID
                )
        }
    }

    private func endSafeOutputInvariantMonitoring() {
        blackHoleMicrophoneOutputAuthorizationGate?.close()
        safeOutputInvariantAuthorization = nil
        blackHoleEndpointPairAuthorization = nil
        blackHoleDefaultInputAuthorization = nil
        guard let epoch = safeOutputInvariantMonitoringEpoch else {
            return
        }
        safeOutputInvariantMonitoringEpoch = nil
        do {
            try worldwideSafeOutputInvariant.endSessionMonitoring(
                epoch: epoch
            )
        } catch {
            logger.error(
                "Safe-output listener cleanup remains degraded: " +
                    error.localizedDescription
            )
        }
    }

    private func recordBlackHoleDefaultInputOutcome(
        _ outcome:
            WorldwideBlackHoleDefaultInputOutcome
    ) {
        switch outcome {
        case .selected(let key):
            logger.info(
                Self.defaultInputSelectionLogMessage(
                    routingEpoch: blackHoleRoutingEpoch,
                    peerGeneration: key.peerGeneration,
                    deviceGeneration: key.deviceGeneration,
                    processIdentifier:
                        ProcessInfo.processInfo
                            .processIdentifier
                )
            )
        case .degraded:
            logger.error(
                "Automatic virtual microphone default-input selection is unavailable; " +
                    "the worldwide media session remains active"
            )
        case .noChange, .waitingForMonitor, .waitingForDevice,
             .released, .suppressed:
            break
        }
    }

    private func iPhoneMicrophoneOutputDidFail(
        output: BlackHoleMicrophoneOutput,
        error: BlackHoleMicrophoneOutputError
    ) async {
        let category =
            Self.iPhoneMicrophoneRuntimeFailureCategory(
                for: error
            )
        let failedKey =
            iPhoneMicrophoneForwarding.snapshot().currentKey

        if case .formatUnsafe(let rejection) = error {
            guard let failedKey,
                  await iPhoneMicrophoneForwarding.handleRuntimeFailure(
                    from: output,
                    category: category
                  ) else {
                return
            }
            iPhoneMicrophoneFormatDidFail(
                key: failedKey,
                rejection: rejection
            )
            return
        }

        if case .sharedClockUnsafe(let rejection) = error {
            guard let failedKey,
                  await iPhoneMicrophoneForwarding.handleRuntimeFailure(
                    from: output,
                    category: category
                  ) else {
                return
            }
            iPhoneMicrophoneSharedClockDidFail(
                key: failedKey,
                rejection: rejection
            )
            return
        }

        // A listener may already have closed the realtime gate while its actor
        // reconciliation is still queued. Revalidate the exact endpoint pair
        // and safe-output proof before the driver can spend this key's retry or
        // synchronously redrive it.
        await consumeCurrentBlackHoleDeviceSnapshot()
        guard await iPhoneMicrophoneForwarding.handleRuntimeFailure(
            from: output,
            category: category
        ) else {
            return
        }
        logger.error(
            Self.iPhoneMicrophoneRuntimeFailureLogMessage(
                error: error
            )
        )
    }

    private func installIPhoneMicrophoneTrack(
        _ track: WebRTCRemoteAudioTrack
    ) async {
        guard track.logicalLane == .iPhoneMicrophone else {
            iPhoneMicrophoneForwarding.clearTrack()
            track.setEnabled(false)
            logger.error(
                "Rejected unexpected worldwide remote audio lane "
                    + track.logicalLane.rawValue
            )
            return
        }
        await iPhoneMicrophoneForwarding.installTrack(track)
    }

    /// Converts unexplained audio-start failure on a healthy route into ICE recovery.
    private func recoverFromSystemAudioStartUncertainty(_ reason: String) async {
        guard !isStopped,
              !isRecovering,
              !recoveryProofRequired,
              // Actor reentrancy can deliver another healthy native event while the first
              // event owns ScreenCaptureKit startup. Pending startup is not route failure; its
              // owner will publish connected or return here with this flag cleared.
              !systemAudioStartInProgress,
              !systemAudioIsLive else {
            return
        }
        await enterRecovery(reason: reason)
        await recoveryCoordinator?.iceStateChanged(.failed)
    }

    /// Closes the current peer generation when bounded recovery cannot restore all gates.
    private func recoveryDidExhaust(peerGeneration generation: UInt64) async {
        guard generation == peerGeneration, !isStopped else {
            return
        }
        if !recoveryProofRequired,
           peerIsConnected,
           iceIsConnected,
           controlChannelIsOpen,
           systemAudioIsLive,
           audioAuthorization?.isValid == true {
            isRecovering = false
            return
        }
        guard isRecovering
                || recoveryProofRequired
                || systemAudioStartInProgress
                || !systemAudioIsLive else { return }
        logger.error("Worldwide ICE recovery exhausted its bounded attempts")
        await stop()
    }

    // MARK: - Native screen capture

    /// Starts ScreenCaptureKit behind a revocable WebRTC control authorization.
    ///
    /// Forwarding begins only after both native startup and a post-await transport-health
    /// check succeed. Any uncertain partial start is synchronously revoked and stopped.
    private func startScreenCapture() async throws -> WebRTCControlAuthorization {
        if captureSource != nil,
           let captureAuthorization,
           captureAuthorization.isValid {
            return captureAuthorization
        }
        guard captureSource == nil else {
            throw WorldwideScreenServiceError.transportUnavailable
        }
        guard transportAllowsCapture else {
            throw WorldwideScreenServiceError.transportUnavailable
        }
        guard let peer, let capturer = peer.externalVideoCapturer else {
            throw WorldwideScreenServiceError.videoCapturerUnavailable
        }

        // Construct the revocable capture gate before the callback sink. ScreenCaptureKit may
        // report an unexpected stop from outside this actor, so the callback must close the gate
        // and revoke controller state synchronously before it schedules actor cleanup.
        let authorization = WebRTCControlAuthorization()
        let inputController = remoteInputController
        let sink = WorldwideScreenSampleSink(capturer: capturer) { [weak self] source, message in
            authorization.revoke()
            inputController.revoke()
            Task {
                await self?.screenCaptureDidStop(
                    source: source,
                    authorization: authorization,
                    message: message
                )
            }
        }
        let source = ScreenVideoCaptureSource(
            displayID: displayID,
            maximumWidth: maximumWidth,
            framesPerSecond: framesPerSecond,
            consumer: sink,
            logger: logger
        )
        captureSink = sink
        captureSource = source
        captureAuthorization = authorization

        do {
            let format = try await source.start()
            let nativeTransportIsHealthy = await peer.isTransportHealthyForCapture()
            guard nativeTransportIsHealthy,
                  captureSource === source,
                  captureAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture else {
                throw WorldwideScreenServiceError.transportUnavailable
            }
            captureDisplayID = format.displayID
            capturer.adaptOutput(
                width: Int32(format.width),
                height: Int32(format.height),
                framesPerSecond: Int32(format.framesPerSecond)
            )
            sink.beginForwarding()
            logger.info(
                "Worldwide screen capture is visible at " +
                "\(format.width)x\(format.height)@\(format.framesPerSecond)"
            )
            return authorization
        } catch {
            let startError = error
            if captureSource === source {
                revokeCaptureAuthorization()
                captureSource = nil
                captureSink = nil
            }
            sink.stopForwarding()
            do {
                // Even a failed post-start health check can leave a native SCStream running.
                // Never turn that uncertainty into a protocol-level Inactive acknowledgement.
                try await source.stop()
            } catch {
                throw WorldwideScreenServiceError.nativeScreenStopFailed(error)
            }
            throw startError
        }
    }

    /// Revokes visibility before awaiting native ScreenCaptureKit shutdown.
    private func stopScreenCapture() async throws {
        revokeCaptureAuthorization()
        let source = captureSource
        let sink = captureSink
        captureSource = nil
        captureSink = nil
        sink?.stopForwarding()
        guard let source else { return }
        try await source.stop()
    }

    /// Handles a native stop only if its source and authorization still own capture.
    private func screenCaptureDidStop(
        source: ScreenVideoCaptureSource,
        authorization: WebRTCControlAuthorization,
        message: String
    ) async {
        guard captureSource === source,
              captureAuthorization === authorization else { return }
        revokeCaptureAuthorization()
        captureSink?.stopForwarding()
        captureSink = nil
        captureSource = nil
        await peer?.suspendScreenMediaForTransportUncertainty()
        logger.error("Worldwide screen capture stopped unexpectedly: \(message)")
    }

    // MARK: - Native system audio

    /// Starts audio for a healthy route and closes on non-recoverable startup failure.
    private func startSystemAudioOrStopSession() async -> Bool {
        guard !systemAudioStartInProgress else { return false }
        do {
            try await startSystemAudio()
            return !isStopped
                && systemAudioIsLive
                && audioSource != nil
                && audioAuthorization?.isValid == true
        } catch {
            guard !isStopped else { return false }
            if isRecovering
                || recoveryProofRequired
                || !transportAllowsCapture
                || isTransportAudioStartCancellation(error) {
                logger.debug(
                    "Worldwide system audio startup yielded to transport recovery: " +
                    error.localizedDescription
                )
                return false
            }
            logger.error("Worldwide system audio failed to start: \(error.localizedDescription)")
            await stop()
            return false
        }
    }

    /// Identifies expected audio-start cancellation caused by concurrent route revocation.
    private func isTransportAudioStartCancellation(_ error: Error) -> Bool {
        guard let transportError = error as? WebRTCTransportError else { return false }
        switch transportError {
        case .transportNotHealthy, .audioAuthorizationRevoked, .transportClosed:
            return true
        default:
            return false
        }
    }

    /// Starts 48 kHz stereo system audio behind a revocable transport authorization.
    ///
    /// Same-peer recovery reuses the exact continuously monitored native source and sink, while
    /// installing a fresh route authorization before forwarding can reopen.
    private func startSystemAudio() async throws {
        guard !systemAudioStartInProgress,
              transportAllowsCapture else {
            throw WorldwideScreenServiceError.transportUnavailable
        }
        guard let peer,
              let capturer = peer.externalAudioCapturer else {
            throw WorldwideScreenServiceError.audioCapturerUnavailable
        }
        let generation = peerGeneration
        let mode = WorldwideSystemAudioRecoveryPolicy.startMode(
            isLive: systemAudioIsLive,
            isPausedForRecovery:
                systemAudioIsPausedForTransportRecovery,
            hasSource: audioSource != nil,
            hasSink: audioSink != nil,
            hasValidAuthorization:
                audioAuthorization?.isValid == true,
            peerGenerationMatches:
                audioPeerGeneration == generation
        )
        guard let mode else {
            throw WorldwideScreenServiceError.transportUnavailable
        }
        if mode == .alreadyLive { return }

        systemAudioStartInProgress = true
        defer { systemAudioStartInProgress = false }

        if mode == .resumeExisting {
            guard let source = audioSource,
                  let sink = audioSink else {
                throw WorldwideScreenServiceError.transportUnavailable
            }
            try await resumeSystemAudio(
                source: source,
                sink: sink,
                peer: peer,
                capturer: capturer,
                peerGeneration: generation
            )
            return
        }

        let authorization = WebRTCAudioAuthorization()
        let sink = WorldwideSystemAudioSampleSink(
            capturer: capturer,
            didObserveMacFaceTimeActivity: {
                [weak self]
                source,
                callbackAuthorization,
                observation,
                evidenceAuthorization in
                Task {
                    await self?.macFaceTimeActivityDidChange(
                        source: source,
                        authorization: callbackAuthorization,
                        observation: observation,
                        evidenceAuthorization: evidenceAuthorization
                    )
                }
            },
            didStop: { [weak self] source, stoppedSink, message in
                Task {
                    await self?.systemAudioCaptureDidStop(
                        source: source,
                        sink: stoppedSink,
                        message: message
                    )
                }
            }
        )
        let source = SystemAudioCaptureSource(
            displayID: displayID,
            consumer: sink,
            logger: logger
        )
        audioSink = sink
        audioSource = source
        audioAuthorization = authorization
        audioPeerGeneration = generation
        systemAudioIsPausedForTransportRecovery = false
        highestMacFaceTimeObservationSequence = 0

        var nativeSourceStarted = false
        do {
            let format = try await source.start()
            nativeSourceStarted = true
            guard audioSource === source,
                  audioSink === sink,
                  audioAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture,
                  self.peer === peer,
                  peerGeneration == generation,
                  audioPeerGeneration == generation else {
                throw WorldwideScreenServiceError.transportUnavailable
            }

            try await peer.enableSystemAudioIfTransportHealthy(
                authorization: authorization
            )
            guard audioSource === source,
                  audioSink === sink,
                  audioAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture,
                  self.peer === peer,
                  peerGeneration == generation,
                  audioPeerGeneration == generation,
                  sink.beginForwarding(with: authorization),
                  authorization.isValid else {
                throw WorldwideScreenServiceError.transportUnavailable
            }

            systemAudioIsLive = true
            systemAudioIsPausedForTransportRecovery = false
            installCurrentMacHostedCallChallenge(on: source)
            logger.info(
                "Worldwide system audio is live from display \(format.displayID) at " +
                "\(format.sampleRate) Hz, \(format.channelCount) channels"
            )
        } catch {
            let stillOwnsNativeSource = audioSource === source
                && audioSink === sink
                && audioPeerGeneration == generation
            if nativeSourceStarted, stillOwnsNativeSource {
                pauseSystemAudioForTransportUncertainty()
                await peer.suspendSystemAudioForTransportUncertainty()
                capturer.reset()

                // A healthy event may complete while native startup is suspended. Resume now so
                // no additional peer event is required to reopen the same source.
                if transportAllowsCapture,
                   self.peer === peer,
                   peerGeneration == generation {
                    try await resumeSystemAudio(
                        source: source,
                        sink: sink,
                        peer: peer,
                        capturer: capturer,
                        peerGeneration: generation
                    )
                    return
                }
            } else if stillOwnsNativeSource {
                revokeSystemAudioAuthorization()
                audioSource = nil
                audioSink = nil
                audioPeerGeneration = nil
                try? await source.stop()
            } else {
                authorization.revoke()
                sink.stopForwarding()
            }
            throw error
        }
    }

    /// Reopens the same native source only after the peer accepts a fresh audio capability.
    private func resumeSystemAudio(
        source: SystemAudioCaptureSource,
        sink: WorldwideSystemAudioSampleSink,
        peer: WebRTCPeer,
        capturer: MacExternalAudioCapturer,
        peerGeneration generation: UInt64
    ) async throws {
        guard audioSource === source,
              audioSink === sink,
              audioPeerGeneration == generation,
              peerGeneration == generation,
              self.peer === peer,
              transportAllowsCapture,
              audioAuthorization == nil else {
            throw WorldwideScreenServiceError.transportUnavailable
        }

        let authorization = WebRTCAudioAuthorization()
        audioAuthorization = authorization
        do {
            try await peer.enableSystemAudioIfTransportHealthy(
                authorization: authorization
            )
            guard audioSource === source,
                  audioSink === sink,
                  audioPeerGeneration == generation,
                  peerGeneration == generation,
                  self.peer === peer,
                  audioAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture,
                  sink.beginForwarding(with: authorization),
                  authorization.isValid else {
                throw WorldwideScreenServiceError.transportUnavailable
            }
            systemAudioIsLive = true
            systemAudioIsPausedForTransportRecovery = false
            installCurrentMacHostedCallChallenge(on: source)
            logger.info(
                "Worldwide system audio resumed on the recovered route"
            )
        } catch {
            if audioSource === source,
               audioSink === sink,
               audioPeerGeneration == generation {
                pauseSystemAudioForTransportUncertainty()
            } else {
                authorization.revoke()
                sink.stopForwarding()
            }
            await peer.suspendSystemAudioForTransportUncertainty()
            capturer.reset()
            throw error
        }
    }

    /// Recovery closes transport capabilities but keeps native call monitoring continuous.
    private func stopSystemAudioForTransportUncertainty(_ reason: String) async {
        guard audioSource != nil || audioAuthorization != nil else {
            return
        }
        pauseSystemAudioForTransportUncertainty()
        logger.info(
            "Paused worldwide system-audio forwarding because \(reason); " +
                "native call monitoring remains continuous"
        )
    }

    /// Revokes forwarding, suspends the track, resets buffered PCM, and stops native capture.
    private func stopSystemAudio() async {
        revokeSystemAudioAuthorization()
        let source = audioSource
        let sink = audioSink
        audioSource = nil
        audioSink = nil
        audioPeerGeneration = nil
        sink?.stopForwarding()
        await peer?.suspendSystemAudioForTransportUncertainty()
        peer?.externalAudioCapturer?.reset()
        guard let source else { return }
        do {
            try await source.stop()
        } catch {
            logger.error("Worldwide system audio stop failed: \(error.localizedDescription)")
        }
    }

    /// Installs a viewer nonce only while this actor owns the exact live process-tap source. The
    /// source performs a new native scan after serially installing the nonce.
    private func installMacHostedCallChallenge(
        _ challenge: WebRTCMacHostedCallChallenge,
        sourcePeer: WebRTCPeer,
        sourcePeerGeneration: UInt64
    ) {
        guard peer === sourcePeer,
              peerGeneration == sourcePeerGeneration,
              sourcePeerGeneration > 0 else {
            return
        }
        guard challenge.isValid else {
            macHostedCallChallenge = nil
            macHostedCallChallengePeerGeneration = nil
            return
        }
        macHostedCallChallenge = challenge
        macHostedCallChallengePeerGeneration = sourcePeerGeneration
        guard let source = audioSource,
              audioAuthorization?.isValid == true,
              systemAudioIsLive,
              transportAllowsCapture else {
            return
        }
        installCurrentMacHostedCallChallenge(on: source)
    }

    /// Reinstalls the actor's current challenge after a route authorization rollover.
    private func installCurrentMacHostedCallChallenge(
        on source: SystemAudioCaptureSource
    ) {
        guard audioSource === source,
              WorldwideMacHostedCallPeerGenerationPolicy.admits(
                  audioPeerGeneration: audioPeerGeneration,
                  challengePeerGeneration:
                      macHostedCallChallengePeerGeneration,
                  currentPeerGeneration: peerGeneration
              ),
              let challenge = macHostedCallChallenge,
              challenge.isValid else {
            return
        }
        _ = source.installMacFaceTimeActivityChallenge(
            SystemAudioMacFaceTimeActivityChallenge(
                sequence: challenge.sequence,
                nonce: challenge.nonce,
                callEpochNonce: challenge.callEpochNonce
            )
        )
    }

    /// Binds every activity heartbeat to the exact live capture source, authorization, peer,
    /// challenge, and monotonically stamped native observation before it reaches the wire.
    private func macFaceTimeActivityDidChange(
        source: SystemAudioCaptureSource,
        authorization: WebRTCAudioAuthorization,
        observation: SystemAudioMacFaceTimeActivityObservation,
        evidenceAuthorization:
            WebRTCMacHostedCallEvidenceAuthorization
    ) async {
        guard audioSource === source,
              audioAuthorization === authorization,
              authorization.isValid,
              systemAudioIsLive,
              transportAllowsCapture,
              WorldwideMacHostedCallPeerGenerationPolicy.admits(
                  audioPeerGeneration: audioPeerGeneration,
                  challengePeerGeneration:
                      macHostedCallChallengePeerGeneration,
                  currentPeerGeneration: peerGeneration
              ),
              let challenge = macHostedCallChallenge,
              WorldwideMacHostedCallObservationPolicy.admits(
                  observationSequence:
                      observation.observationSequence,
                  highestAdmittedSequence:
                      highestMacFaceTimeObservationSequence,
                  observationChallenge: observation.challenge,
                  currentChallenge: challenge
              ),
              let peer,
              self.peer === peer else {
            return
        }
        highestMacFaceTimeObservationSequence =
            observation.observationSequence
        guard let evidenceState =
            WorldwideMacHostedCallEvidenceStatePolicy.state(
                isCausallyBoundActive:
                    observation.isCausallyBoundActive,
                isCausallyArmed: observation.isCausallyArmed
            ) else {
            return
        }
        do {
            try await peer.updateMacHostedCallEvidenceIfTransportHealthy(
                state: evidenceState,
                challenge: challenge,
                nativeObservationSequence:
                    observation.observationSequence,
                authorization: authorization,
                evidenceAuthorization: evidenceAuthorization
            )
        } catch let error as WebRTCTransportError {
            switch error {
            case .transportNotHealthy,
                 .audioAuthorizationRevoked,
                 .macHostedCallEvidenceAuthorizationRevoked,
                 .transportClosed:
                // A missing heartbeat is intentionally fail-closed on the iPhone.
                break
            default:
                logger.error(
                    "Mac-hosted call evidence send failed: "
                        + error.localizedDescription
                )
            }
        } catch {
            logger.error(
                "Mac-hosted call evidence send failed: "
                    + error.localizedDescription
            )
        }
    }

    /// Fails the consume-once session when its current native audio source stops unexpectedly.
    private func systemAudioCaptureDidStop(
        source: SystemAudioCaptureSource,
        sink: WorldwideSystemAudioSampleSink,
        message: String
    ) async {
        guard audioSource === source,
              audioSink === sink else { return }
        revokeSystemAudioAuthorization()
        audioSink = nil
        audioSource = nil
        audioPeerGeneration = nil
        await peer?.suspendSystemAudioForTransportUncertainty()
        peer?.externalAudioCapturer?.reset()
        logger.error("Worldwide system audio stopped unexpectedly: \(message)")
        await stop()
    }

    /// Revokes one route while retaining the exact source/sink and native causal binder.
    private func pauseSystemAudioForTransportUncertainty() {
        systemAudioIsLive = false
        systemAudioIsPausedForTransportRecovery =
            audioSource != nil
                && audioSink != nil
                && audioPeerGeneration == peerGeneration
        let authorization = audioAuthorization
        audioAuthorization = nil
        audioSink?.stopForwarding()
        authorization?.revoke()
        peer?.externalAudioCapturer?.reset()
    }

    /// Synchronously closes audio authorization and clears external capturer buffers.
    private func revokeSystemAudioAuthorization() {
        systemAudioIsLive = false
        systemAudioIsPausedForTransportRecovery = false
        macHostedCallChallenge = nil
        macHostedCallChallengePeerGeneration = nil
        highestMacFaceTimeObservationSequence = 0
        let authorization = audioAuthorization
        audioAuthorization = nil
        audioSink?.stopForwarding()
        authorization?.revoke()
        peer?.externalAudioCapturer?.reset()
    }

    /// Revokes remote input before the screen capability that authorized it.
    private func revokeCaptureAuthorization() {
        // Input revocation is first and synchronous: no queued tap or key may outlive the
        // screen authorization boundary that made the capability valid.
        revokeRemoteInputAuthorization()
        captureDisplayID = nil
        captureAuthorization?.revoke()
        captureAuthorization = nil
    }
}

/// Wire feedback plus the local decision to revoke the current input capability.
private struct RemoteInputTransportFeedback {
    let result: WebRTCInputFeedbackResult
    let rejectionReason: WebRTCInputRejectionReason?
    let focus: WebRTCInputFocus
    let revokesSession: Bool

    static func accepted(focus: WebRTCInputFocus) -> Self {
        Self(
            result: .accepted,
            rejectionReason: nil,
            focus: focus,
            revokesSession: false
        )
    }

    static func rejected(
        reason: WebRTCInputRejectionReason,
        revokesSession: Bool
    ) -> Self {
        Self(
            result: .rejected,
            rejectionReason: reason,
            focus: .none,
            revokesSession: revokesSession
        )
    }
}

/// Hide request used as proof that a particular recovery epoch is media-inactive.
private struct PendingRecoveryProofRequest: Equatable {
    let id: UInt64
    let epoch: UInt64
}

/// Transport capability and revocable authorization installed for one Show request.
private struct ArmedRemoteInputSession {
    let capability: WebRTCInputCapability
    let authorization: WebRTCInputAuthorization
}

/// Thread-safe gate between ScreenCaptureKit callbacks and the WebRTC video capturer.
///
/// The lock closes forwarding synchronously on actor-driven revocation or native stop;
/// samples arriving after either boundary are discarded before touching WebRTC.
private final class WorldwideScreenSampleSink: ScreenVideoSampleConsumer, @unchecked Sendable {
    private let capturer: MacExternalVideoCapturer
    private let didStop: @Sendable (ScreenVideoCaptureSource, String) -> Void
    private let lock = NSLock()
    private var isForwarding = false

    init(
        capturer: MacExternalVideoCapturer,
        didStop: @escaping @Sendable (ScreenVideoCaptureSource, String) -> Void
    ) {
        self.capturer = capturer
        self.didStop = didStop
    }

    /// Opens the callback gate after capture and transport health are proven.
    func beginForwarding() {
        lock.withLock { isForwarding = true }
    }

    /// Closes the callback gate synchronously.
    func stopForwarding() {
        lock.withLock { isForwarding = false }
    }

    /// Forwards image-backed, timestamped samples only while the gate is open.
    func consumeScreenVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard lock.withLock({ isForwarding }),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid else { return }
        capturer.capture(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    func screenVideoCaptureSource(
        _ source: ScreenVideoCaptureSource,
        didStopWithErrorDescription errorDescription: String
    ) {
        stopForwarding()
        didStop(source, errorDescription)
    }
}

/// Lock-owned callback capability that can be rolled to a fresh transport authorization without
/// replacing the continuously monitored native source. Audio is always acquired before causal
/// evidence, matching `WebRTCPeer`'s global authorization order.
final class WorldwideSystemAudioForwardingGate: @unchecked Sendable {
    private struct EvidenceTransition {
        let retired: WebRTCMacHostedCallEvidenceAuthorization?
        let delivery: WebRTCMacHostedCallEvidenceAuthorization?
    }

    private let lock = NSLock()
    private var isForwarding = false
    private var isTerminated = false
    private var authorization: WebRTCAudioAuthorization?
    private var macHostedCallCausalBindingID: UUID?
    private var macHostedCallEvidenceAuthorization:
        WebRTCMacHostedCallEvidenceAuthorization?

    /// Installs one fresh route capability. A prior route must be synchronously paused first.
    @discardableResult
    func beginForwarding(
        with authorization: WebRTCAudioAuthorization
    ) -> Bool {
        do {
            return try authorization.withValidAuthorization {
                lock.withLock {
                    if isForwarding,
                       self.authorization === authorization {
                        return true
                    }
                    guard !isForwarding,
                          self.authorization == nil,
                          !isTerminated else {
                        return false
                    }
                    self.authorization = authorization
                    isForwarding = true
                    return true
                }
            }
        } catch {
            return false
        }
    }

    /// Closes PCM and evidence synchronously, then revokes the old capabilities in lock order.
    func stopForwarding() {
        closeForwarding(terminal: false)
    }

    /// Permanently closes a gate whose native source has failed.
    func terminate() {
        closeForwarding(terminal: true)
    }

    private func closeForwarding(terminal: Bool) {
        let retired = lock.withLock {
            let retired = (
                authorization,
                macHostedCallEvidenceAuthorization
            )
            isForwarding = false
            isTerminated = isTerminated || terminal
            authorization = nil
            macHostedCallCausalBindingID = nil
            macHostedCallEvidenceAuthorization = nil
            return retired
        }
        retired.0?.revoke()
        retired.1?.revoke()
    }

    var authorizationSnapshot: WebRTCAudioAuthorization? {
        lock.withLock {
            guard isForwarding else { return nil }
            return authorization
        }
    }

    /// Rechecks exact token identity under the callback gate after acquiring the audio token.
    @discardableResult
    func withCurrentAuthorization(
        _ candidate: WebRTCAudioAuthorization,
        operation: () -> Void
    ) -> Bool {
        do {
            return try candidate.withValidAuthorization {
                lock.withLock {
                    guard isForwarding,
                          authorization === candidate else {
                        return false
                    }
                    operation()
                    return true
                }
            }
        } catch {
            return false
        }
    }

    /// Creates or reuses evidence only for the exact native binding and call epoch sampled.
    @discardableResult
    func withEvidenceAuthorization(
        for observation: SystemAudioMacFaceTimeActivityObservation,
        operation: (
            WebRTCAudioAuthorization,
            WebRTCMacHostedCallEvidenceAuthorization
        ) -> Void
    ) -> Bool {
        guard let candidate = authorizationSnapshot else { return false }
        do {
            return try candidate.withValidAuthorization {
                let transition = lock.withLock { () -> EvidenceTransition in
                    guard isForwarding,
                          authorization === candidate else {
                        return EvidenceTransition(
                            retired: nil,
                            delivery: nil
                        )
                    }
                    guard let challenge = observation.challenge,
                          Self.isValid(challenge) else {
                        return retireEvidenceLocked()
                    }

                    if let bindingID = observation.causalBindingID,
                       macHostedCallCausalBindingID == bindingID,
                       let current =
                            macHostedCallEvidenceAuthorization,
                       current.callEpochNonce
                            == challenge.callEpochNonce,
                       current.isValid {
                        return EvidenceTransition(
                            retired: nil,
                            delivery: current
                        )
                    }

                    let retired = macHostedCallEvidenceAuthorization
                    let replacement =
                        WebRTCMacHostedCallEvidenceAuthorization(
                            callEpochNonce: challenge.callEpochNonce
                        )
                    macHostedCallCausalBindingID =
                        observation.causalBindingID
                    // Non-active evidence is one-shot: the next observation replaces it instead of
                    // reusing it, while retaining it here lets a recovery pause revoke it.
                    macHostedCallEvidenceAuthorization = replacement
                    return EvidenceTransition(
                        retired: retired,
                        delivery: replacement
                    )
                }
                transition.retired?.revoke()
                guard let evidenceAuthorization = transition.delivery else {
                    return false
                }
                operation(candidate, evidenceAuthorization)
                return true
            }
        } catch {
            return false
        }
    }

    private func retireEvidenceLocked() -> EvidenceTransition {
        let retired = macHostedCallEvidenceAuthorization
        macHostedCallCausalBindingID = nil
        macHostedCallEvidenceAuthorization = nil
        return EvidenceTransition(retired: retired, delivery: nil)
    }

    private static func isValid(
        _ challenge: SystemAudioMacFaceTimeActivityChallenge
    ) -> Bool {
        challenge.sequence > 0
            && challenge.nonce != zeroUUID
            && challenge.callEpochNonce != zeroUUID
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Thread-safe, doubly authorized bridge from system-audio callbacks into WebRTC.
final class WorldwideSystemAudioSampleSink: SystemAudioSampleConsumer, @unchecked Sendable {
    private let capturer: MacExternalAudioCapturer
    private let gate: WorldwideSystemAudioForwardingGate
    private let didObserveMacFaceTimeActivity:
        @Sendable (
            SystemAudioCaptureSource,
            WebRTCAudioAuthorization,
            SystemAudioMacFaceTimeActivityObservation,
            WebRTCMacHostedCallEvidenceAuthorization
        ) -> Void
    private let didStop:
        @Sendable (
            SystemAudioCaptureSource,
            WorldwideSystemAudioSampleSink,
            String
        ) -> Void

    init(
        capturer: MacExternalAudioCapturer,
        gate: WorldwideSystemAudioForwardingGate =
            WorldwideSystemAudioForwardingGate(),
        didObserveMacFaceTimeActivity:
            @escaping @Sendable (
                SystemAudioCaptureSource,
                WebRTCAudioAuthorization,
                SystemAudioMacFaceTimeActivityObservation,
                WebRTCMacHostedCallEvidenceAuthorization
            ) -> Void,
        didStop:
            @escaping @Sendable (
                SystemAudioCaptureSource,
                WorldwideSystemAudioSampleSink,
                String
            ) -> Void
    ) {
        self.capturer = capturer
        self.gate = gate
        self.didObserveMacFaceTimeActivity =
            didObserveMacFaceTimeActivity
        self.didStop = didStop
    }

    @discardableResult
    func beginForwarding(
        with authorization: WebRTCAudioAuthorization
    ) -> Bool {
        gate.beginForwarding(with: authorization)
    }

    func stopForwarding() {
        gate.stopForwarding()
    }

    func consumeSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let authorization = gate.authorizationSnapshot else {
            return
        }
        gate.withCurrentAuthorization(authorization) {
            capturer.capture(sampleBuffer: sampleBuffer)
        }
    }

    func consumeSystemAudioFrames(
        _ audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        frameCount: UInt32,
        presentationTime: CMTime
    ) {
        guard let authorization = gate.authorizationSnapshot else {
            return
        }
        gate.withCurrentAuthorization(authorization) {
            capturer.capture(
                audioBufferList: audioBufferList,
                format: format,
                frameCount: frameCount,
                presentationTime: presentationTime
            )
        }
    }

    func systemAudioCaptureSource(
        _ source: SystemAudioCaptureSource,
        didStopWithErrorDescription errorDescription: String
    ) {
        gate.terminate()
        capturer.reset()
        didStop(source, self, errorDescription)
    }

    func systemAudioCaptureSource(
        _ source: SystemAudioCaptureSource,
        didObserveMacFaceTimeActivity observation:
            SystemAudioMacFaceTimeActivityObservation
    ) {
        gate.withEvidenceAuthorization(for: observation) {
            authorization, evidenceAuthorization in
            didObserveMacFaceTimeActivity(
                source,
                authorization,
                observation,
                evidenceAuthorization
            )
        }
    }
}

/// Lifecycle, transport-health, and rendezvous failures for one media session.
private enum WorldwideScreenServiceError: LocalizedError {
    case invalidLifecycle
    case signalBeforeReady
    case videoCapturerUnavailable
    case audioCapturerUnavailable
    case transportUnavailable
    case microphoneInputAdmissionUnavailable
    case microphoneInputReleaseUnproved
    case microphoneWriterAuthorizationSuperseded
    case nativeScreenStopFailed(any Error)
    case rendezvous(RendezvousServerError)

    var errorDescription: String? {
        switch self {
        case .invalidLifecycle:
            "The worldwide screen service cannot be started in its current state."
        case .signalBeforeReady:
            "The rendezvous delivered signaling before the WebRTC peer was ready."
        case .videoCapturerUnavailable:
            "The Mac WebRTC screen capturer is unavailable."
        case .audioCapturerUnavailable:
            "The Mac WebRTC system-audio capturer is unavailable."
        case .transportUnavailable:
            "The secure media transport is not healthy enough to expose the screen."
        case .microphoneInputAdmissionUnavailable:
            "The visible microphone input lease could not be proven."
        case .microphoneInputReleaseUnproved:
            "The visible microphone input lease could not be released before output-route repair."
        case .microphoneWriterAuthorizationSuperseded:
            "A newer Mac output-route event superseded microphone writer admission."
        case .nativeScreenStopFailed(let error):
            "The native screen source could not confirm that capture stopped " +
                "(\(error.localizedDescription))."
        case .rendezvous(let error):
            "The rendezvous rejected the session (\(String(describing: error)))."
        }
    }
}

private extension NSLock {
    /// Runs a synchronous critical section and always releases the lock.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
