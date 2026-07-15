import CaptureCore
import CoreMedia
import Foundation
import RemoteSessionCore
import WebRTCTransport

/// Owns one consume-once invitation and its Mac-side WebRTC screen session.
///
/// The invitation authenticates and encrypts signaling. Reachability still comes from
/// ICE/STUN and, when a direct candidate pair is impossible, the configured TURN service.
actor WorldwideScreenService {
    nonisolated let completion: AsyncStream<Void>

    private let invitation: RemoteInvitationCode
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
    private var activeInputCapability: WebRTCInputCapability?
    private var activeInputAuthorization: WebRTCInputAuthorization?
    private var isStarted = false
    private var isStopped = false

    private var transportAllowsCapture: Bool {
        peerIsConnected
            && iceIsConnected
            && controlChannelIsOpen
            && !isRecovering
            && !isStopped
    }

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

    /// Starts the outbound rendezvous connection and deliberately returns the secret once
    /// for presentation to the user. Callers must never put this value in routine logs.
    func start() async throws -> String {
        guard !isStarted, !isStopped else {
            throw WorldwideScreenServiceError.invalidLifecycle
        }
        isStarted = true

        do {
            let events = try await signaling.connect()
            signalingTask = Task { [weak self] in
                await self?.consumeSignalingEvents(events)
            }
            logger.info("Worldwide screen host is waiting for a one-time viewer")
            return invitation.exportedCode
        } catch {
            isStopped = true
            completionContinuation.finish()
            throw error
        }
    }

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
        await coordinator?.cancel()
        await stopScreenCapture()
        if let peer {
            await peer.close(reason: .hostStopped)
        }
        self.peer = nil
        await signaling.close()
        completionContinuation.yield(())
        completionContinuation.finish()
    }

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

    private func handleSignalingEvent(_ event: RendezvousSignalingEvent) async throws {
        switch event {
        case .waiting(let invitationExpiresAt):
            let remaining = max(0, Int(invitationExpiresAt.timeIntervalSinceNow.rounded()))
            logger.info("One-time invitation is waiting (expires in about \(remaining) seconds)")

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
            await stopScreenCaptureForTransportUncertainty(
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
            logger.info("Worldwide viewer disconnected; this one-time invitation is consumed")
            await stop()

        case .serverError(let error):
            throw WorldwideScreenServiceError.rendezvous(error)
        }
    }

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

    private func handlePeerEvent(_ event: WebRTCTransportEvent) async throws {
        switch event {
        case .outboundSignal(let payload):
            try await signaling.send(payload)

        case .peerStateChanged(let state):
            logger.info("Worldwide WebRTC peer state: \(state.rawValue)")
            switch state {
            case .new, .connecting:
                peerIsConnected = false
            case .connected:
                peerIsConnected = true
                if recoveryProofRequired, let peer {
                    await completePendingRecoveryProofIfPossible(
                        peer: peer,
                        epoch: recoveryProofEpoch
                    )
                } else if markRecoveryHealthyIfPossible() {
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
                } else if markRecoveryHealthyIfPossible() {
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
                let previouslyAuthorizedRoute = iceIsConnected || captureSource != nil
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
            controlChannelIsOpen = state == .open
            if state == .open {
                if recoveryProofRequired, let peer {
                    await completePendingRecoveryProofIfPossible(
                        peer: peer,
                        epoch: recoveryProofEpoch
                    )
                } else if markRecoveryHealthyIfPossible() {
                    await recoveryCoordinator?.iceStateChanged(.connected)
                }
            }
            if state == .closing || state == .closed {
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

        case .iceCandidateError(let error):
            logger.error(
                "Worldwide ICE probe failed for \(error.url) " +
                "from \(error.address):\(error.port) [\(error.errorCode)]: \(error.reason)"
            )

        case .diagnosticFailure(let message):
            logger.error("Worldwide WebRTC diagnostic: \(message)")

        case .ended:
            await stop()

        case .identityReceived, .remoteVideoTrack, .negotiationNeeded:
            break
        }
    }

    private func handleControlRequest(_ request: WebRTCControlRequest) async {
        guard let peer else {
            await stopScreenCapture()
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
            var activeAcknowledgementWasSent = false
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
                activeAcknowledgementWasSent = true
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
                    await stopScreenCapture()
                    await peer.suspendScreenMediaForTransportUncertainty()
                    logger.error("Worldwide screen authorization changed during Active acknowledgement")
                    return
                }
            } catch {
                await stopScreenCapture()
                if !activeAcknowledgementWasSent {
                    try? await peer.acknowledgeControlRequest(id: request.id, state: .inactive)
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
                await stopScreenCapture()
                await completePendingRecoveryProofIfPossible(
                    peer: peer,
                    epoch: proofRequest.epoch
                )
                return
            }

            await stopScreenCapture()
            do {
                try await peer.acknowledgeControlRequest(id: request.id, state: .inactive)
            } catch {
                logger.error("Worldwide screen Hide acknowledgement failed: \(error.localizedDescription)")
            }

        case .requestKeyFrame:
            // RTP feedback remains WebRTC-owned; acknowledge the screen state without reusing a
            // VideoToolbox frame from the legacy path.
            if let source = captureSource,
               let authorization = captureAuthorization,
               authorization.isValid,
               transportAllowsCapture {
                let authorizationPeerGeneration = peerGeneration
                let authorizationRecoveryEpoch = recoveryProofEpoch
                var activeAcknowledgementWasSent = false
                do {
                    try await peer.acknowledgeControlRequestIfTransportHealthy(
                        id: request.id,
                        state: .active,
                        authorization: authorization
                    )
                    activeAcknowledgementWasSent = true
                    guard authorizationPeerGeneration == peerGeneration,
                          authorizationRecoveryEpoch == recoveryProofEpoch,
                          self.peer === peer,
                          captureSource === source,
                          captureAuthorization === authorization,
                          authorization.isValid,
                          transportAllowsCapture else {
                        await stopScreenCapture()
                        await peer.suspendScreenMediaForTransportUncertainty()
                        logger.error("Worldwide key-frame state changed during acknowledgement")
                        return
                    }
                } catch {
                    await stopScreenCapture()
                    if !activeAcknowledgementWasSent {
                        try? await peer.acknowledgeControlRequest(
                            id: request.id,
                            state: .inactive
                        )
                    }
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
                screenRequestID: screenRequestID
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

    private func injectRemoteInput(_ request: WebRTCInputRequest) -> MacRemoteInputResult {
        switch request.action {
        case .tap(let point):
            remoteInputController.handleTap(
                screenRequestID: request.screenRequestID,
                inputSessionID: request.inputSessionID,
                normalizedPoint: .init(x: point.x, y: point.y)
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
        case .insertText:
            return "committed-text"
        case .backspace:
            return "backspace"
        case .returnKey:
            return "return"
        }
    }

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
            case .injectionFailed:
                reason = .injectionFailed
                revokesSession = false
            }
            return .rejected(reason: reason, revokesSession: revokesSession)
        }
    }

    private func revokeRemoteInputAuthorization() {
        activeInputAuthorization?.revoke()
        activeInputAuthorization = nil
        remoteInputController.revoke()
        activeInputCapability = nil
    }

    private func stopScreenCaptureForTransportUncertainty(_ reason: String) async {
        guard captureSource != nil else { return }
        // Privacy is fail-closed: a recovered peer must receive a fresh, acknowledged Show.
        logger.info("Stopping worldwide screen capture because \(reason)")
        await stopScreenCapture()
    }

    private func beginICERestart(
        peer: WebRTCPeer,
        peerGeneration generation: UInt64
    ) async throws {
        guard generation == peerGeneration, !isStopped, self.peer != nil else {
            throw CancellationError()
        }
        let epoch = installRecoveryProofBoundary(awaitingAnswer: true)
        await stopScreenCaptureForTransportUncertainty("an ICE restart began")
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

    private func enterRecovery(reason: String) async {
        isRecovering = true
        revokeCaptureAuthorization()
        if recoveryProofRequired {
            // Invalidate a pre-uncertainty Hide/ACK without severing the current offer→answer
            // epoch. Native disconnected events are expected during an in-flight restart.
            recoveryProofAuthorization?.revoke()
            recoveryProofAuthorization = WebRTCControlAuthorization()
            pendingRecoveryProofRequest = nil
            recoveryProofAcknowledgementInFlight = nil
        }
        await stopScreenCaptureForTransportUncertainty(reason)
    }

    @discardableResult
    private func installRecoveryProofBoundary(awaitingAnswer: Bool) -> UInt64 {
        revokeCaptureAuthorization()
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
        await recoveryCoordinator?.iceStateChanged(.connected)
    }

    @discardableResult
    private func markRecoveryHealthyIfPossible() -> Bool {
        guard !recoveryProofRequired,
              peerIsConnected,
              iceIsConnected,
              controlChannelIsOpen else {
            return false
        }
        isRecovering = false
        return true
    }

    private func recoveryDidExhaust(peerGeneration generation: UInt64) async {
        guard generation == peerGeneration, !isStopped else {
            return
        }
        if !recoveryProofRequired,
           peerIsConnected,
           iceIsConnected,
           controlChannelIsOpen {
            isRecovering = false
            return
        }
        guard isRecovering || recoveryProofRequired else { return }
        logger.error("Worldwide ICE recovery exhausted its bounded attempts")
        await stop()
    }

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
                if captureSource === source {
                    revokeCaptureAuthorization()
                    captureSource = nil
                    captureSink = nil
                }
                sink.stopForwarding()
                try? await source.stop()
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
            if captureSource === source {
                revokeCaptureAuthorization()
                captureSource = nil
                captureSink = nil
            }
            sink.stopForwarding()
            throw error
        }
    }

    private func stopScreenCapture() async {
        revokeCaptureAuthorization()
        let source = captureSource
        let sink = captureSink
        captureSource = nil
        captureSink = nil
        sink?.stopForwarding()
        guard let source else { return }
        do {
            try await source.stop()
        } catch {
            logger.error("Worldwide screen capture stop failed: \(error.localizedDescription)")
        }
    }

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

    private func revokeCaptureAuthorization() {
        // Input revocation is first and synchronous: no queued tap or key may outlive the
        // screen authorization boundary that made the capability valid.
        revokeRemoteInputAuthorization()
        captureDisplayID = nil
        captureAuthorization?.revoke()
        captureAuthorization = nil
    }
}

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

private struct PendingRecoveryProofRequest: Equatable {
    let id: UInt64
    let epoch: UInt64
}

private struct ArmedRemoteInputSession {
    let capability: WebRTCInputCapability
    let authorization: WebRTCInputAuthorization
}

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

    func beginForwarding() {
        lock.withLock { isForwarding = true }
    }

    func stopForwarding() {
        lock.withLock { isForwarding = false }
    }

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

private enum WorldwideScreenServiceError: LocalizedError {
    case invalidLifecycle
    case signalBeforeReady
    case videoCapturerUnavailable
    case transportUnavailable
    case rendezvous(RendezvousServerError)

    var errorDescription: String? {
        switch self {
        case .invalidLifecycle:
            "The worldwide screen service cannot be started in its current state."
        case .signalBeforeReady:
            "The rendezvous delivered signaling before the WebRTC peer was ready."
        case .videoCapturerUnavailable:
            "The Mac WebRTC screen capturer is unavailable."
        case .transportUnavailable:
            "The secure media transport is not healthy enough to expose the screen."
        case .rendezvous(let error):
            "The rendezvous rejected the session (\(String(describing: error)))."
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
