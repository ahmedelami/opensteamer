import CaptureCore
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

/// Minimal lifecycle surface shared by the production AudioQueue sink and deterministic fakes.
protocol WorldwideIPhoneMicrophoneOutput: AnyObject, Sendable {
    func start() throws
    func stop()
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

    private let invitation: RemoteInvitationCode?
    private let signaling: RendezvousSignalingClient
    private let icePolicy: WebRTCICEPolicy
    private let displayID: UInt32?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let maximumVideoBitrate: Int
    private let remoteInputController: MacRemoteInputController
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
    private var systemAudioStartInProgress = false
    private var systemAudioIsLive = false
    private var iPhoneMicrophoneTrack: WebRTCRemoteAudioTrack?
    private lazy var iPhoneMicrophoneForwarding =
        WorldwideIPhoneMicrophoneForwardingCoordinator<
            WebRTCPeer,
            WebRTCRemoteAudioTrack
        >(
            makeOutput: { [weak self] peer in
                guard let self,
                      let source = peer.macDecodedAudioSource else {
                    return nil
                }
                return BlackHoleMicrophoneOutput(
                    source: source,
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
            admit: { peer, track in
                try await peer.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
                    track
                )
            },
            disableTrack: { track in
                track.setEnabled(false)
            }
        )
    private var activeInputCapability: WebRTCInputCapability?
    private var activeInputAuthorization: WebRTCInputAuthorization?
    private var isStarted = false
    private var isStopped = false

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

        do {
            let events = try await signaling.connect()
            signalingTask = Task { [weak self] in
                await self?.consumeSignalingEvents(events)
            }
        } catch {
            isStopped = true
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
        stopIPhoneMicrophoneForwarding(clearTrack: true)
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
        stopIPhoneMicrophoneForwarding(clearTrack: true)
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
        recoveryCoordinator = coordinator
        let events = peer.events
        peerEventTask = Task { [weak self] in
            await self?.consumePeerEvents(events)
        }
        try await peer.startStatistics()
        try await peer.start()
        logger.info("Worldwide WebRTC negotiation started")
    }

    /// Consumes native peer events until normal stop or an unexpected stream end.
    private func consumePeerEvents(_ events: AsyncStream<WebRTCTransportEvent>) async {
        for await event in events {
            guard !isStopped else { return }
            do {
                try await handlePeerEvent(event)
            } catch is CancellationError {
                return
            } catch {
                logger.error("Worldwide WebRTC session failed: \(error.localizedDescription)")
                await stop()
                return
            }
        }
        guard !Task.isCancelled, !isStopped else { return }
        logger.error("Worldwide WebRTC event stream ended unexpectedly")
        await stop()
    }

    /// Updates transport health, routes protocol requests, and emits sanitized diagnostics.
    private func handlePeerEvent(_ event: WebRTCTransportEvent) async throws {
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

        case .controlReceived:
            // Legacy signaling controls deliberately cannot start worldwide capture because they
            // do not provide the request ID and completion acknowledgement required by the v2 path.
            logger.debug("Ignored legacy worldwide screen control without acknowledgement")

        case .routeChanged(let route):
            logger.info("Worldwide WebRTC route: \(route.kind.rawValue)")

        case .statistics(let snapshot):
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
            if let diagnostics = peer?.externalAudioCapturer?.runtimeDiagnostics() {
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
        revokeSystemAudioAuthorization()
        captureSink?.stopForwarding()
        audioSink?.stopForwarding()
        stopIPhoneMicrophoneForwarding(clearTrack: false)
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
        revokeSystemAudioAuthorization()
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
        revokeSystemAudioAuthorization()
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
        guard await startSystemAudioOrStopSession() else {
            await recoverFromSystemAudioStartUncertainty(
                "system audio could not be enabled after route proof"
            )
            return
        }
        await startIPhoneMicrophoneForwardingIfPossible()
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
        guard await startSystemAudioOrStopSession() else {
            await recoverFromSystemAudioStartUncertainty(
                "system audio could not be enabled on the healthy route"
            )
            return false
        }
        await startIPhoneMicrophoneForwardingIfPossible()
        return true
    }

    // MARK: - iPhone microphone to BlackHole

    private func iPhoneMicrophoneOutputDidFail(
        output: BlackHoleMicrophoneOutput,
        error: BlackHoleMicrophoneOutputError
    ) {
        guard iPhoneMicrophoneForwarding.handleRuntimeFailure(
            from: output
        ) else {
            return
        }

        logger.error(
            "iPhone microphone forwarding stopped after an AudioQueue failure: "
                + error.localizedDescription
        )
    }

    private func installIPhoneMicrophoneTrack(
        _ track: WebRTCRemoteAudioTrack
    ) async {
        guard track.logicalLane == .iPhoneMicrophone else {
            track.setEnabled(false)
            logger.error(
                "Rejected unexpected worldwide remote audio lane "
                    + track.logicalLane.rawValue
            )
            return
        }
        stopIPhoneMicrophoneForwarding(clearTrack: true)
        iPhoneMicrophoneTrack = track
        await startIPhoneMicrophoneForwardingIfPossible()
    }

    private func startIPhoneMicrophoneForwardingIfPossible() async {
        guard transportAllowsCapture,
              let peer,
              let track = iPhoneMicrophoneTrack else {
            return
        }

        do {
            let result = try await iPhoneMicrophoneForwarding.start(
                peer: peer,
                track: track
            )
            guard result == .started else { return }
        } catch {
            logger.error(
                "iPhone microphone forwarding is unavailable: "
                    + error.localizedDescription
            )
            return
        }

        guard transportAllowsCapture,
              self.peer === peer,
              iPhoneMicrophoneTrack === track else {
            iPhoneMicrophoneForwarding.stopIfCurrent(
                peer: peer,
                track: track
            )
            return
        }
        logger.info(
            "Forwarding the authorized iPhone microphone to BlackHole 2ch"
        )
    }

    private func stopIPhoneMicrophoneForwarding(clearTrack: Bool) {
        iPhoneMicrophoneForwarding.stopCurrent()
        iPhoneMicrophoneTrack?.setEnabled(false)
        if clearTrack {
            iPhoneMicrophoneTrack = nil
        }
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
    /// WebRTC audio is enabled and revalidated before the callback sink begins forwarding;
    /// failure resets the external capturer so stale PCM cannot enter a later route.
    private func startSystemAudio() async throws {
        if systemAudioIsLive,
           audioSource != nil,
           let audioAuthorization,
           audioAuthorization.isValid {
            return
        }
        guard !systemAudioStartInProgress,
              audioSource == nil,
              transportAllowsCapture else {
            throw WorldwideScreenServiceError.transportUnavailable
        }
        guard let peer, let capturer = peer.externalAudioCapturer else {
            throw WorldwideScreenServiceError.audioCapturerUnavailable
        }
        systemAudioStartInProgress = true

        let authorization = WebRTCAudioAuthorization()
        let sink = WorldwideSystemAudioSampleSink(
            capturer: capturer,
            authorization: authorization
        ) { [weak self] source, message in
            authorization.revoke()
            Task {
                await self?.systemAudioCaptureDidStop(
                    source: source,
                    authorization: authorization,
                    message: message
                )
            }
        }
        let source = SystemAudioCaptureSource(
            displayID: displayID,
            consumer: sink,
            logger: logger
        )
        audioSink = sink
        audioSource = source
        audioAuthorization = authorization

        do {
            let format = try await source.start()
            guard audioSource === source,
                  audioAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture,
                  self.peer === peer else {
                throw WorldwideScreenServiceError.transportUnavailable
            }

            try await peer.enableSystemAudioIfTransportHealthy(
                authorization: authorization
            )
            guard audioSource === source,
                  audioAuthorization === authorization,
                  authorization.isValid,
                  transportAllowsCapture,
                  self.peer === peer else {
                throw WorldwideScreenServiceError.transportUnavailable
            }

            sink.beginForwarding()
            systemAudioIsLive = true
            systemAudioStartInProgress = false
            logger.info(
                "Worldwide system audio is live from display \(format.displayID) at " +
                "\(format.sampleRate) Hz, \(format.channelCount) channels"
            )
        } catch {
            if audioSource === source {
                revokeSystemAudioAuthorization()
                audioSource = nil
                audioSink = nil
            }
            sink.stopForwarding()
            await peer.suspendSystemAudioForTransportUncertainty()
            capturer.reset()
            try? await source.stop()
            systemAudioStartInProgress = false
            systemAudioIsLive = false
            throw error
        }
    }

    /// Logs the recovery boundary before stopping an installed audio source.
    private func stopSystemAudioForTransportUncertainty(_ reason: String) async {
        guard audioSource != nil || audioAuthorization != nil else { return }
        logger.info("Stopping worldwide system audio because \(reason)")
        await stopSystemAudio()
    }

    /// Revokes forwarding, suspends the track, resets buffered PCM, and stops native capture.
    private func stopSystemAudio() async {
        revokeSystemAudioAuthorization()
        let source = audioSource
        let sink = audioSink
        audioSource = nil
        audioSink = nil
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

    /// Fails the consume-once session when its current native audio source stops unexpectedly.
    private func systemAudioCaptureDidStop(
        source: SystemAudioCaptureSource,
        authorization: WebRTCAudioAuthorization,
        message: String
    ) async {
        guard audioSource === source,
              audioAuthorization === authorization else { return }
        revokeSystemAudioAuthorization()
        audioSink?.stopForwarding()
        audioSink = nil
        audioSource = nil
        await peer?.suspendSystemAudioForTransportUncertainty()
        peer?.externalAudioCapturer?.reset()
        logger.error("Worldwide system audio stopped unexpectedly: \(message)")
        await stop()
    }

    /// Synchronously closes audio authorization and clears external capturer buffers.
    private func revokeSystemAudioAuthorization() {
        systemAudioIsLive = false
        audioAuthorization?.revoke()
        audioAuthorization = nil
        audioSink?.stopForwarding()
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

/// Thread-safe, doubly authorized bridge from system-audio callbacks into WebRTC.
///
/// Both the lock gate and revocable audio token must remain valid. This lets route
/// uncertainty stop PCM synchronously even while native ScreenCaptureKit teardown awaits.
private final class WorldwideSystemAudioSampleSink: SystemAudioSampleConsumer, @unchecked Sendable {
    private let capturer: MacExternalAudioCapturer
    private let authorization: WebRTCAudioAuthorization
    private let didStop: @Sendable (SystemAudioCaptureSource, String) -> Void
    private let lock = NSLock()
    private var isForwarding = false

    init(
        capturer: MacExternalAudioCapturer,
        authorization: WebRTCAudioAuthorization,
        didStop: @escaping @Sendable (SystemAudioCaptureSource, String) -> Void
    ) {
        self.capturer = capturer
        self.authorization = authorization
        self.didStop = didStop
    }

    /// Opens forwarding after WebRTC has enabled and revalidated its audio track.
    func beginForwarding() {
        lock.withLock { isForwarding = true }
    }

    /// Closes forwarding synchronously at the transport boundary.
    func stopForwarding() {
        lock.withLock { isForwarding = false }
    }

    /// Sends a buffer only while both authorization and forwarding remain active.
    func consumeSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        do {
            try authorization.withValidAuthorization {
                guard lock.withLock({ isForwarding }) else { return }
                capturer.capture(sampleBuffer: sampleBuffer)
            }
        } catch {
            // Revocation is the normal boundary for Hide-independent transport teardown.
        }
    }

    func systemAudioCaptureSource(
        _ source: SystemAudioCaptureSource,
        didStopWithErrorDescription errorDescription: String
    ) {
        authorization.revoke()
        stopForwarding()
        capturer.reset()
        didStop(source, errorDescription)
    }
}

/// Lifecycle, transport-health, and rendezvous failures for one media session.
private enum WorldwideScreenServiceError: LocalizedError {
    case invalidLifecycle
    case signalBeforeReady
    case videoCapturerUnavailable
    case audioCapturerUnavailable
    case transportUnavailable
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
