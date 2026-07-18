import AudioToolbox
import CoreGraphics
import Foundation
import RemoteSessionCore
import WebRTCTransport

@MainActor
final class WorldwideSessionViewModel: ObservableObject {
    @Published private(set) var stateText = "Not connected"
    @Published private(set) var lastError: String?
    @Published private(set) var lastDiagnostic: String?
    @Published private(set) var lastICECandidateError: WebRTCIceCandidateError?
    @Published private(set) var isConnecting = false
    @Published private(set) var isPeerConnected = false
    @Published private(set) var isControlChannelReady = false
    @Published private(set) var isScreenVisible = false
    @Published private(set) var remoteVideoTrack: WebRTCRemoteVideoTrack?
    @Published private(set) var audioStateText = "Inactive"
    @Published private(set) var isRemoteAudioAvailable = false
    @Published private(set) var isRemoteAudioPlaying = false
    @Published private(set) var audioRequiresExplicitResume = false
    @Published private(set) var audioError: String?
    @Published private(set) var audioDiagnostic: String?
    @Published private(set) var routeText = "Unknown"
    @Published private(set) var iceStateText = "Inactive"
    @Published private(set) var remoteDisplayName = "Mac mini"
    @Published private(set) var invitationExpiresAt: Date?
    @Published private(set) var statistics: WebRTCStatisticsSnapshot?
    @Published private(set) var remoteInputCapability: WebRTCInputCapability?
    @Published private(set) var focusedInputGeneration: UInt64?
    @Published private(set) var focusedInputIsSecure = false

    private var signaling: RendezvousSignalingClient?
    private var peer: WebRTCPeer?
    private var remoteAudioTrack: WebRTCRemoteAudioTrack?
    private let audioLifecycle: WorldwideAudioLifecycleController
    private var recoveryCoordinator: ICERecoveryCoordinator?
    private var nextICERestartRequestID: UInt64 = 1
    private var iceIsConnected = false
    private var sessionTask: Task<Void, Never>?
    private var peerEventTask: Task<Void, Never>?
    private var audioPlayoutProofTask: Task<Void, Never>?
    private var controlAcknowledgementTimeoutTask: Task<Void, Never>?
    private var pendingScreenVisibilityRequest: PendingScreenVisibilityRequest?
    private var earlyControlAcknowledgements: [UInt64: ReceivedControlAcknowledgement] = [:]
    private var sessionGeneration = UUID()
    private var hasHandledRemoteOffer = false
    private var recoveryProofEpoch: UInt64 = 0
    private var recoveryProofRequired = false
    private var restartAnswerAwaitingSendEpoch: UInt64?
    private var pendingRecoveryProbe: PendingRecoveryProbe?
    private var remoteInputQueue: [QueuedRemoteInput] = []
    private var remoteInputDrainTask: Task<Void, Never>?
    private var remoteInputGeneration = UUID()
    private var pendingRemoteInputs: [UInt64: PendingRemoteInput] = [:]
    private var pendingRemoteInputOrder: [UInt64] = []
    private var earlyRemoteInputFeedback: [UInt64: WebRTCInputFeedback] = [:]
    private var latestPointerIntentID: UInt64 = 0
    private var remoteInputAuthorization: WebRTCInputAuthorization?
    private var acceptsActiveScreenAcknowledgement = false
    private var remoteHideRequired = false
    private var screenVisibilityOperationGeneration = UUID()
    #if DEBUG
    private var debugScreenVisibilityRequestSender: (@MainActor (Bool) async throws -> UInt64)?
    #endif

    init(audioLifecycle: WorldwideAudioLifecycleController = WorldwideAudioLifecycleController()) {
        self.audioLifecycle = audioLifecycle
        audioLifecycle.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            audioStateText = snapshot.stateText
            isRemoteAudioAvailable = snapshot.isRemoteAudioAvailable
            isRemoteAudioPlaying = snapshot.isPlaying
            audioRequiresExplicitResume = snapshot.requiresExplicitResume
            audioError = snapshot.errorText
            audioDiagnostic = snapshot.diagnosticText
        }
        audioLifecycle.onPlaybackRecoveryRequested = { [weak self] in
            self?.beginIOSPlayoutProof(requestRecovery: true)
        }
    }

    var hasActiveSession: Bool {
        signaling != nil || peer != nil || sessionTask != nil
    }

    var canViewScreen: Bool {
        isPeerConnected && iceIsConnected && isControlChannelReady
    }

    var isRemoteInputAvailable: Bool {
        remoteInputCapability != nil
            && remoteInputAuthorization?.isValid == true
            && isScreenVisible
            && canViewScreen
    }

    var isRemotePrimaryDragAvailable: Bool {
        isRemoteInputAvailable && remoteInputCapability?.supportsPrimaryDrag == true
    }

    var canResumeAudioPlayback: Bool {
        hasActiveSession
            && (audioRequiresExplicitResume || audioStateText == "Playback unavailable")
    }

    var audioRecoveryButtonTitle: String {
        audioStateText == "Playback unavailable" ? "Retry Audio" : "Resume Audio"
    }

    #if DEBUG
    /// Test-only legacy constructor used to exercise the downstream audio lifecycle. Production
    /// UI can enter this view model only with a fresh paired-session signaling client.
    @discardableResult
    func debugConnectWithInvitationForTests(
        invitationCode input: String,
        debugEndpointOverride: String? = nil,
        beforeAudioActivation: @MainActor () -> Void = {}
    ) -> Bool {
        guard !isConnecting, !hasActiveSession else { return false }

        let invitation: RemoteInvitationCode
        do {
            invitation = try RemoteInvitationCode(input)
        } catch {
            stateText = "Invalid invitation"
            lastError = "Check the invitation code shown on the Mac and try again."
            return false
        }

        guard let endpoint = Self.rendezvousEndpoint(debugOverride: debugEndpointOverride) else {
            stateText = "Service unavailable"
            lastError = "This build does not have a worldwide rendezvous endpoint configured."
            return false
        }

        let client: RendezvousSignalingClient
        do {
            client = try RendezvousSignalingClient(
                endpoint: endpoint,
                invitation: invitation,
                role: .viewer
            )
        } catch {
            stateText = "Service unavailable"
            lastError = error.localizedDescription
            return false
        }

        return connect(
            signalingClient: client,
            beforeAudioActivation: beforeAudioActivation
        )
    }
    #endif

    /// Starts ordinary WebRTC signaling only after bootstrap/availability produced a fresh,
    /// one-use session client. Pairing secrets never enter this media lifecycle.
    @discardableResult
    func connect(
        signalingClient client: RendezvousSignalingClient,
        beforeAudioActivation: @MainActor () -> Void = {}
    ) -> Bool {
        guard !isConnecting, !hasActiveSession else { return false }

        // Validation is complete. Release any other process-wide audio-session owner only when
        // this worldwide attempt can actually proceed to WebRTC audio activation.
        beforeAudioActivation()
        resetPublishedSessionState()
        audioLifecycle.prepare(serverName: remoteDisplayName)
        isConnecting = true
        stateText = "Connecting securely"
        signaling = client
        sessionGeneration = UUID()
        nextICERestartRequestID = 1
        hasHandledRemoteOffer = false
        recoveryProofEpoch = 0
        recoveryProofRequired = false
        restartAnswerAwaitingSendEpoch = nil
        pendingRecoveryProbe = nil
        let generation = sessionGeneration
        sessionTask = Task { [weak self] in
            await self?.runSession(client: client, generation: generation)
        }
        return true
    }

    func disconnect() {
        tearDown(reason: .viewerDisconnected)
        resetPublishedSessionState()
        stateText = "Not connected"
    }

    /// Keeps authenticated audio playout alive while independently closing the screen/input
    /// presentation boundary for privacy.
    func handleAppBecameActive() {
        audioLifecycle.appBecameActive()
    }

    func handleAppBecameInactive() {
        audioLifecycle.appBecameInactive()
        hideScreenForPassiveLifecycleIfNeeded()
    }

    func handleAppEnteredBackground() {
        audioLifecycle.appEnteredBackground()
        hideScreenForPassiveLifecycleIfNeeded()
    }

    func resumeAudioPlayback() {
        audioLifecycle.resumePlayback()
    }

    /// Immediately closes the local input gate before UI code starts an asynchronous Hide.
    /// `setScreenVisible(false)` repeats this revocation so non-view callers remain fail closed.
    func suspendRemoteInputPresentation() {
        invalidateRemoteInputState()
    }

    /// Revokes local input synchronously, before passive UI/lifecycle teardown schedules Hide.
    /// The injectable operation keeps the ordering boundary directly regression-testable.
    func beginPassiveScreenTeardown() {
        beginPassiveScreenTeardown { [weak self] in
            guard let self else { return }
            await self.setScreenVisible(false)
        }
    }

    func beginPassiveScreenTeardown(
        hideOperation: @escaping @MainActor () async -> Void
    ) {
        suspendRemoteInputPresentation()
        remoteHideRequired = remoteHideRequired
            || isScreenVisible
            || pendingScreenVisibilityRequest?.isVisible == true
            || acceptsActiveScreenAcknowledgement
        acceptsActiveScreenAcknowledgement = false
        // Invalidate any Show/Hide call currently suspended in an actor-reentrant peer send.
        // The scheduled Hide below becomes the sole visibility operation allowed to install
        // an acknowledgement continuation after it begins.
        screenVisibilityOperationGeneration = UUID()
        completePendingScreenVisibilityRequest(success: false)
        // Keep the confirmed visibility state until the scheduled Hide consumes it.
        // `remoteHideRequired` also covers a Show already sent before local visibility became
        // true, so cancelling that pending continuation cannot make false -> false take the
        // ordinary no-op fast path.
        clearEarlyControlAcknowledgements()
        Task { @MainActor in
            await hideOperation()
        }
    }

    @discardableResult
    func setScreenVisible(_ visible: Bool) async -> Bool {
        let operationGeneration = UUID()
        screenVisibilityOperationGeneration = operationGeneration
        if visible {
            acceptsActiveScreenAcknowledgement = true
        } else {
            acceptsActiveScreenAcknowledgement = false
            invalidateRemoteInputState()
        }
        let visibilityPeer = peer
        guard screenVisibilityTransportIsAvailable(visibilityPeer) else {
            if visible {
                acceptsActiveScreenAcknowledgement = false
                lastError = "The secure screen-control channel is not ready yet."
            } else {
                isScreenVisible = false
                remoteHideRequired = false
                return true
            }
            return false
        }
        // Passive lifecycle notifications are global and may arrive while a worldwide peer is
        // merely negotiating. A locally hidden screen with no remembered remote Show is already
        // at the safe target and must not tear down that unrelated connection.
        if !visible, visibilityRequestCanReuseCurrentState(false) {
            return true
        }
        guard canViewScreen else {
            if visible {
                acceptsActiveScreenAcknowledgement = false
                lastError = "The secure screen-control channel is not ready yet."
            } else {
                isScreenVisible = false
                failSession(
                    "The Mac could not be told to stop screen sharing, so the session was closed for privacy.",
                    generation: sessionGeneration
                )
            }
            return false
        }
        if visibilityRequestCanReuseCurrentState(visible) {
            return true
        }

        // A later Hide must supersede an in-flight Show (and vice versa). The ordered channel
        // preserves command order, while request IDs ensure a late acknowledgement cannot win.
        completePendingScreenVisibilityRequest(success: false)
        let generation = sessionGeneration
        if visible {
            remoteHideRequired = true
        }

        do {
            let requestID = try await sendScreenVisibilityRequest(
                visible,
                expectedPeer: visibilityPeer
            )
            guard generation == sessionGeneration,
                  screenVisibilityTransportStillMatches(visibilityPeer),
                  operationGeneration == screenVisibilityOperationGeneration,
                  !visible || acceptsActiveScreenAcknowledgement else {
                return false
            }
            stateText = visible ? "Starting Mac screen" : "Stopping Mac screen"

            let reachedTarget = await withCheckedContinuation { continuation in
                if let received = earlyControlAcknowledgements.removeValue(forKey: requestID) {
                    let reachedTarget = applyControlAcknowledgement(
                        received.acknowledgement,
                        inputAuthorization: received.inputAuthorization,
                        requestedVisibility: visible
                    )
                    continuation.resume(returning: reachedTarget)
                    return
                }

                pendingScreenVisibilityRequest = PendingScreenVisibilityRequest(
                    id: requestID,
                    isVisible: visible,
                    sessionGeneration: generation,
                    operationGeneration: operationGeneration,
                    continuation: continuation
                )
                controlAcknowledgementTimeoutTask?.cancel()
                controlAcknowledgementTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    self?.controlAcknowledgementTimedOut(
                        requestID: requestID,
                        generation: generation,
                        operationGeneration: operationGeneration
                    )
                }
            }
            guard generation == sessionGeneration,
                  screenVisibilityTransportStillMatches(visibilityPeer),
                  operationGeneration == screenVisibilityOperationGeneration else {
                return false
            }
            if !visible, !reachedTarget {
                failSession(
                    "The Mac did not confirm that screen sharing stopped, so the session was closed for privacy.",
                    generation: generation
                )
            }
            return reachedTarget
        } catch {
            guard generation == sessionGeneration,
                  screenVisibilityTransportStillMatches(visibilityPeer),
                  operationGeneration == screenVisibilityOperationGeneration else {
                return false
            }
            if !visible {
                isScreenVisible = false
                failSession(
                    "The Mac could not be told to stop screen sharing, so the session was closed for privacy.",
                    generation: generation
                )
                return false
            } else {
                acceptsActiveScreenAcknowledgement = false
                failSession(
                    "The Mac could not confirm whether screen sharing started, so the session was closed for privacy.",
                    generation: generation
                )
                return false
            }
        }
    }

    private func visibilityRequestCanReuseCurrentState(_ visible: Bool) -> Bool {
        pendingScreenVisibilityRequest == nil
            && visible == isScreenVisible
            && (visible || !remoteHideRequired)
    }

    private func screenVisibilityTransportIsAvailable(_ expectedPeer: WebRTCPeer?) -> Bool {
        if expectedPeer != nil { return true }
        #if DEBUG
        return debugScreenVisibilityRequestSender != nil
        #else
        return false
        #endif
    }

    private func screenVisibilityTransportStillMatches(_ expectedPeer: WebRTCPeer?) -> Bool {
        if let expectedPeer {
            return peer === expectedPeer
        }
        #if DEBUG
        return peer == nil && debugScreenVisibilityRequestSender != nil
        #else
        return false
        #endif
    }

    private func sendScreenVisibilityRequest(
        _ visible: Bool,
        expectedPeer: WebRTCPeer?
    ) async throws -> UInt64 {
        #if DEBUG
        if let debugScreenVisibilityRequestSender {
            return try await debugScreenVisibilityRequestSender(visible)
        }
        #endif
        guard let expectedPeer else {
            throw WorldwideSessionError.screenControlUnavailable
        }
        return try await expectedPeer.setScreenVisible(visible)
    }

    func sendRemoteTap(normalizedPoint: CGPoint) {
        guard isRemoteInputAvailable,
              normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite else {
            return
        }

        let pointerIntentID = beginRemotePointerIntent()
        enqueueRemoteInput(
            .tap(
                .init(
                    x: Double(normalizedPoint.x),
                    y: Double(normalizedPoint.y)
                )
            ),
            pointerIntentID: pointerIntentID
        )
    }

    func sendRemotePrimaryDrag(
        startNormalizedPoint: CGPoint,
        endNormalizedPoint: CGPoint
    ) {
        guard isRemotePrimaryDragAvailable,
              startNormalizedPoint.x.isFinite,
              startNormalizedPoint.y.isFinite,
              endNormalizedPoint.x.isFinite,
              endNormalizedPoint.y.isFinite else {
            return
        }

        let pointerIntentID = beginRemotePointerIntent()
        enqueueRemoteInput(
            .primaryDrag(
                start: .init(
                    x: Double(startNormalizedPoint.x),
                    y: Double(startNormalizedPoint.y)
                ),
                end: .init(
                    x: Double(endNormalizedPoint.x),
                    y: Double(endNormalizedPoint.y)
                )
            ),
            pointerIntentID: pointerIntentID
        )
    }

    private func beginRemotePointerIntent() -> UInt64 {
        latestPointerIntentID &+= 1
        if latestPointerIntentID == 0 { latestPointerIntentID = 1 }
        clearRemoteKeyboardFocus()
        return latestPointerIntentID
    }

    func sendRemoteText(_ text: String, focusGeneration: UInt64) {
        guard focusedInputGeneration == focusGeneration,
              WebRTCInputAction.isValidCommittedText(text) else { return }
        enqueueRemoteInput(.insertText(text, focusGeneration: focusGeneration))
    }

    func sendRemoteBackspace(focusGeneration: UInt64) {
        guard focusedInputGeneration == focusGeneration else { return }
        enqueueRemoteInput(.backspace(focusGeneration: focusGeneration))
    }

    func sendRemoteReturn(focusGeneration: UInt64) {
        guard focusedInputGeneration == focusGeneration else { return }
        enqueueRemoteInput(.returnKey(focusGeneration: focusGeneration))
    }

    private func enqueueRemoteInput(
        _ action: WebRTCInputAction,
        pointerIntentID: UInt64? = nil
    ) {
        guard let capability = remoteInputCapability,
              let authorization = remoteInputAuthorization,
              authorization.isValid,
              isRemoteInputAvailable else {
            return
        }
        guard remoteInputQueue.count < 128 else {
            lastDiagnostic = "Remote input was paused because its local queue filled."
            invalidateRemoteInputState()
            return
        }

        remoteInputQueue.append(
            QueuedRemoteInput(
                action: action,
                capability: capability,
                authorization: authorization,
                sessionGeneration: sessionGeneration,
                inputGeneration: remoteInputGeneration,
                pointerIntentID: pointerIntentID
            )
        )
        startRemoteInputDrainIfNeeded()
    }

    private func startRemoteInputDrainIfNeeded() {
        guard remoteInputDrainTask == nil, !remoteInputQueue.isEmpty else { return }
        let inputGeneration = remoteInputGeneration
        remoteInputDrainTask = Task { [weak self] in
            await self?.drainRemoteInputQueue(inputGeneration: inputGeneration)
        }
    }

    private func remoteInputActionMatchesCurrentFocus(_ action: WebRTCInputAction) -> Bool {
        switch action {
        case .tap, .primaryDrag:
            return true
        case .insertText(_, let generation),
             .backspace(let generation),
             .returnKey(let generation):
            return focusedInputGeneration == generation
        }
    }

    private func drainRemoteInputQueue(inputGeneration: UUID) async {
        defer {
            if inputGeneration == remoteInputGeneration {
                remoteInputDrainTask = nil
                startRemoteInputDrainIfNeeded()
            }
        }

        while !Task.isCancelled,
              inputGeneration == remoteInputGeneration,
              !remoteInputQueue.isEmpty {
            let queued = remoteInputQueue.removeFirst()
            guard queued.inputGeneration == inputGeneration,
                  queued.sessionGeneration == sessionGeneration,
                  queued.capability == remoteInputCapability,
                  queued.authorization === remoteInputAuthorization,
                  queued.authorization.isValid,
                  let peer,
                  isRemoteInputAvailable,
                  remoteInputActionMatchesCurrentFocus(queued.action) else {
                continue
            }

            guard pendingRemoteInputs.count < 256 else {
                lastDiagnostic = "Remote input was paused because feedback did not arrive."
                invalidateRemoteInputState()
                return
            }

            do {
                guard !Task.isCancelled, queued.authorization.isValid else { return }
                let requestID = try await peer.sendInput(
                    queued.action,
                    capability: queued.capability,
                    authorization: queued.authorization
                )
                guard !Task.isCancelled,
                      inputGeneration == remoteInputGeneration,
                      queued.sessionGeneration == sessionGeneration,
                      self.peer === peer,
                      queued.capability == remoteInputCapability,
                      queued.authorization === remoteInputAuthorization,
                      queued.authorization.isValid else {
                    continue
                }
                pendingRemoteInputs[requestID] = PendingRemoteInput(
                    kind: PendingRemoteInputKind(queued.action),
                    pointerIntentID: queued.pointerIntentID
                )
                pendingRemoteInputOrder.append(requestID)

                if let feedback = earlyRemoteInputFeedback.removeValue(forKey: requestID) {
                    handleRemoteInputFeedback(feedback)
                }
            } catch {
                if let transportError = error as? WebRTCTransportError,
                   transportError == .invalidInputRequest {
                    clearRemoteKeyboardFocus()
                    remoteInputQueue.removeAll(where: { $0.action.requiresRemoteFocus })
                    lastDiagnostic = "The remote input action was not valid."
                    continue
                }
                lastDiagnostic = "Remote input paused because its secure control path is unavailable."
                invalidateRemoteInputState()
                return
            }
        }
    }

    private func runSession(
        client: RendezvousSignalingClient,
        generation: UUID
    ) async {
        defer {
            if generation == sessionGeneration {
                sessionTask = nil
                isConnecting = false
            }
        }

        do {
            let events = try await client.connect()
            for try await event in events {
                guard !Task.isCancelled, generation == sessionGeneration else { return }
                try await handleSignalingEvent(
                    event,
                    client: client,
                    generation: generation
                )
            }

            guard !Task.isCancelled, generation == sessionGeneration else { return }
            failSession("The rendezvous connection closed.", generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            failSession(error.localizedDescription, generation: generation)
        }
    }

    private func handleSignalingEvent(
        _ event: RendezvousSignalingEvent,
        client: RendezvousSignalingClient,
        generation: UUID
    ) async throws {
        switch event {
        case .waiting(let expiration):
            invitationExpiresAt = expiration
            stateText = "Waiting for Mac"

        case .ready(_, let expiration, let iceServers):
            invitationExpiresAt = expiration
            guard peer == nil else { return }
            // Ready proves only that rendezvous admitted both roles. It does not authenticate
            // either device and therefore cannot clear the one-time invitation.

            let newPeer = try WebRTCPeer(
                configuration: WebRTCTransportConfiguration(
                    role: .viewer,
                    iceServers: iceServers,
                    icePolicy: .directPreferred
                )
            )
            let coordinator = ICERecoveryCoordinator(
                restart: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.sendICERestartRequest(
                        client: client,
                        generation: generation
                    )
                },
                exhausted: { [weak self] in
                    await self?.iceRecoveryDidExhaust(generation: generation)
                }
            )
            peer = newPeer
            recoveryCoordinator = coordinator
            startPeerEventLoop(peer: newPeer, signaling: client, generation: generation)
            try await newPeer.startStatistics()
            isConnecting = true
            stateText = "Negotiating secure media"

        case .signal(let payload):
            guard let peer else {
                throw WorldwideSessionError.signalBeforeReady
            }
            let isOffer: Bool
            if case .offer = payload {
                isOffer = true
                if hasHandledRemoteOffer {
                    markTransportUncertain(
                        "Recovering secure media",
                        requiresProof: true
                    )
                    restartAnswerAwaitingSendEpoch = recoveryProofEpoch
                }
            } else {
                isOffer = false
            }
            try await peer.handle(payload)
            guard generation == sessionGeneration, self.peer === peer else { return }
            if isOffer {
                hasHandledRemoteOffer = true
            }

        case .peerLeft:
            throw WorldwideSessionError.macDisconnected

        case .serverError(let error):
            throw WorldwideSessionError.server(error)
        }
    }

    private func startPeerEventLoop(
        peer: WebRTCPeer,
        signaling: RendezvousSignalingClient,
        generation: UUID
    ) {
        peerEventTask?.cancel()
        peerEventTask = Task { [weak self] in
            for await event in peer.events {
                guard !Task.isCancelled else { return }
                await self?.handlePeerEvent(
                    event,
                    signaling: signaling,
                    generation: generation
                )
            }
            guard !Task.isCancelled else { return }
            self?.peerEventStreamEnded(peer: peer, generation: generation)
        }
    }

    private func peerEventStreamEnded(peer: WebRTCPeer, generation: UUID) {
        guard generation == sessionGeneration,
              self.peer === peer,
              hasActiveSession else {
            return
        }
        failSession("The secure media event stream closed.", generation: generation)
    }

    private func handlePeerEvent(
        _ event: WebRTCTransportEvent,
        signaling: RendezvousSignalingClient,
        generation: UUID
    ) async {
        guard generation == sessionGeneration else { return }

        switch event {
        case .outboundSignal(let payload):
            do {
                try await signaling.send(payload)
                guard generation == sessionGeneration,
                      self.signaling === signaling else {
                    return
                }
                if case .answer = payload,
                   let epoch = restartAnswerAwaitingSendEpoch,
                   epoch == recoveryProofEpoch,
                   recoveryProofRequired,
                   let peer,
                   self.peer === peer {
                    restartAnswerAwaitingSendEpoch = nil
                    await sendRecoveryProbe(
                        peer: peer,
                        generation: generation,
                        epoch: epoch
                    )
                }
            } catch {
                guard generation == sessionGeneration else { return }
                failSession(error.localizedDescription, generation: generation)
            }

        case .peerStateChanged(let state):
            await handlePeerState(state, generation: generation)

        case .iceStateChanged(let state):
            iceStateText = state.displayText
            switch state {
            case .connected, .completed:
                guard !recoveryProofRequired else {
                    iceIsConnected = false
                    stateText = "Recovering secure media"
                    break
                }
                iceIsConnected = true
                await markViewerTransportHealthyIfPossible(state)
            case .disconnected, .failed:
                iceIsConnected = false
                markTransportUncertain("Recovering secure media")
                await recoveryCoordinator?.iceStateChanged(state)
            case .closed:
                iceIsConnected = false
                await recoveryCoordinator?.iceStateChanged(state)
                failSession("The secure media connection closed.", generation: generation)
            case .new, .checking, .unknown:
                let crossedHealthyBoundary = iceIsConnected
                    || isScreenVisible
                    || remoteInputCapability != nil
                if crossedHealthyBoundary {
                    iceIsConnected = false
                    markTransportUncertain("Recovering secure media")
                    await recoveryCoordinator?.iceStateChanged(.disconnected)
                }
            }

        case .iceGatheringStateChanged:
            break

        case .dataChannelStateChanged(let state):
            isControlChannelReady = state == .open
            if state == .open {
                await markViewerTransportHealthyIfPossible(.connected)
            } else if state == .closing || state == .closed {
                // The Mac also stops capture on these states. A recovered channel therefore
                // requires a fresh acknowledged Show instead of silently resuming video.
                markTransportUncertain("Recovering secure media")
                await recoveryCoordinator?.iceStateChanged(.failed)
            }

        case .controlRequestReceived:
            // Only the Mac host receives viewer control requests.
            break

        case .controlAcknowledgementReceived(let acknowledgement, let inputAuthorization):
            await handleControlAcknowledgement(
                acknowledgement,
                inputAuthorization: inputAuthorization
            )

        case .inputRequestReceived:
            // Only the Mac host receives viewer input requests.
            break

        case .inputFeedbackReceived(let feedback):
            handleRemoteInputFeedback(feedback)

        case .inputSessionInvalidated:
            invalidateRemoteInputState()

        case .controlReceived:
            break

        case .identityReceived(let identity):
            if let displayName = identity.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                remoteDisplayName = displayName
                audioLifecycle.updateServerName(displayName)
            }

        case .remoteAudioTrack(let track):
            remoteAudioTrack = track
            audioLifecycle.remoteAudioBecameAvailable(track)
            beginIOSPlayoutProof(requestRecovery: false)

        case .remoteVideoTrack(let track):
            remoteVideoTrack = track
            if isScreenVisible {
                stateText = "Screen live"
            }

        case .routeChanged(let route):
            routeText = route.kind.displayText

        case .statistics(let snapshot):
            statistics = snapshot
            refreshIOSPlayoutProof()

        case .iceCandidateError(let error):
            // ICE may still select a healthy route through a different interface or URL.
            // Actual peer/ICE failure and bounded recovery remain the user-facing authority.
            lastICECandidateError = error

        case .negotiationNeeded:
            break

        case .ended:
            failSession("The Mac ended the remote session.", generation: generation)

        case .diagnosticFailure(let message):
            // Individual ICE probes can fail on an interface or optional server while another
            // candidate pair is already carrying media. Keep that evidence for Diagnostics,
            // but let ICE/peer state transitions decide whether the user has an actionable error.
            lastDiagnostic = message
        }
    }

    private func handlePeerState(_ state: WebRTCPeerState, generation: UUID) async {
        switch state {
        case .new, .connecting:
            let crossedHealthyBoundary = isPeerConnected
                || isScreenVisible
                || remoteInputCapability != nil
            isPeerConnected = false
            if crossedHealthyBoundary {
                markTransportUncertain("Recovering secure media")
                await recoveryCoordinator?.iceStateChanged(.disconnected)
            } else {
                stateText = "Connecting media"
            }
        case .connected:
            isConnecting = false
            isPeerConnected = true
            await markViewerTransportHealthyIfPossible(.connected)
        case .disconnected:
            isPeerConnected = false
            markTransportUncertain("Recovering secure media")
            await recoveryCoordinator?.iceStateChanged(.disconnected)
        case .failed:
            isPeerConnected = false
            markTransportUncertain("Recovering secure media")
            await recoveryCoordinator?.iceStateChanged(.failed)
        case .closed:
            if hasActiveSession {
                failSession("The secure media connection closed.", generation: generation)
            }
        }
    }

    private func failSession(_ message: String, generation: UUID) {
        guard generation == sessionGeneration else { return }
        tearDown(reason: .protocolError)
        resetPublishedSessionState()
        stateText = "Connection failed"
        lastError = message
    }

    private func tearDown(reason: RemoteSessionEndReason) {
        audioLifecycle.stop()
        remoteAudioTrack = nil
        acceptsActiveScreenAcknowledgement = false
        remoteHideRequired = false
        screenVisibilityOperationGeneration = UUID()
        invalidateRemoteInputState()
        completePendingScreenVisibilityRequest(success: false)
        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        clearEarlyControlAcknowledgements()
        hasHandledRemoteOffer = false
        recoveryProofEpoch = 0
        recoveryProofRequired = false
        restartAnswerAwaitingSendEpoch = nil
        pendingRecoveryProbe = nil
        let oldRecoveryCoordinator = recoveryCoordinator
        recoveryCoordinator = nil
        sessionGeneration = UUID()
        sessionTask?.cancel()
        peerEventTask?.cancel()
        audioPlayoutProofTask?.cancel()

        let oldSignaling = signaling
        let oldPeer = peer
        sessionTask = nil
        peerEventTask = nil
        audioPlayoutProofTask = nil
        signaling = nil
        peer = nil
        iceIsConnected = false
        nextICERestartRequestID = 1

        Task {
            await oldRecoveryCoordinator?.cancel()
            await oldPeer?.close(reason: reason)
            await oldSignaling?.close()
        }
    }

    private func resetPublishedSessionState() {
        acceptsActiveScreenAcknowledgement = false
        remoteHideRequired = false
        screenVisibilityOperationGeneration = UUID()
        invalidateRemoteInputState()
        lastError = nil
        lastDiagnostic = nil
        lastICECandidateError = nil
        isConnecting = false
        isPeerConnected = false
        isControlChannelReady = false
        iceIsConnected = false
        isScreenVisible = false
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        audioStateText = "Inactive"
        isRemoteAudioAvailable = false
        isRemoteAudioPlaying = false
        audioRequiresExplicitResume = false
        audioError = nil
        audioDiagnostic = nil
        routeText = "Unknown"
        iceStateText = "Inactive"
        remoteDisplayName = "Mac mini"
        invitationExpiresAt = nil
        statistics = nil
    }

    /// A signaling/ICE success is not proof that iOS is actually rendering full-band stereo.
    /// Poll the custom output-only RemoteIO long enough to observe its realtime callback, and
    /// publish the native failure instead of claiming "Playing" on a call/HFP-style route.
    private func beginIOSPlayoutProof(requestRecovery: Bool) {
        audioPlayoutProofTask?.cancel()
        guard let proofPeer = peer else { return }
        let generation = sessionGeneration
        audioPlayoutProofTask = Task { [weak self] in
            guard let self else { return }
            if requestRecovery {
                await proofPeer.requestIOSPlayoutRecovery()
            }

            for _ in 0..<40 {
                guard !Task.isCancelled,
                      generation == sessionGeneration,
                      peer === proofPeer else { return }
                if let diagnostics = await proofPeer.iOSPlayoutDiagnostics(),
                   applyIOSPlayoutDiagnostics(diagnostics) {
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  generation == sessionGeneration,
                  peer === proofPeer else { return }
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                failureMessage: "The iPhone audio output did not start in full-quality stereo.",
                diagnostic: "RemoteIO produced no verified playout callback within two seconds."
            )
        }
    }

    private func refreshIOSPlayoutProof() {
        guard let proofPeer = peer else { return }
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self,
                  generation == sessionGeneration,
                  peer === proofPeer,
                  let diagnostics = await proofPeer.iOSPlayoutDiagnostics() else { return }
            _ = applyIOSPlayoutDiagnostics(diagnostics)
        }
    }

    /// Returns true once the snapshot is terminal for the current proof attempt: either verified
    /// media playout or a concrete native failure. Incomplete startup snapshots keep polling.
    @discardableResult
    private func applyIOSPlayoutDiagnostics(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        let usesRemoteIO = diagnostics.audioUnitSubType == kAudioUnitSubType_RemoteIO
        let isHealthy = diagnostics.initialized
            && diagnostics.playoutInitialized
            && diagnostics.playing
            && diagnostics.sessionActive
            && diagnostics.ownsSessionActivation
            && diagnostics.remoteIOCreated
            && !diagnostics.inputBusEnabled
            && diagnostics.outputBusEnabled
            && !diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
            && diagnostics.categoryIsMediaPlayback
            && diagnostics.modeIsDefault
            && abs(diagnostics.sampleRate - 48_000) < 1
            && diagnostics.outputChannelCount == 2
            && usesRemoteIO
            && diagnostics.playoutCallbackCount > 0
            && diagnostics.playoutFailureCount == 0
            && diagnostics.unexpectedRecordingRequestCount == 0
            && diagnostics.lastPlayoutStatus == noErr

        if isHealthy {
            audioLifecycle.updateRuntimePlayout(isReady: true)
            return true
        }

        let nativeFailure = diagnostics.failureCode != 0
            || diagnostics.playoutFailureCount > 0
            || diagnostics.unexpectedRecordingRequestCount > 0
            || diagnostics.lastPlayoutStatus != noErr
            || diagnostics.recoveryRequired
            || diagnostics.explicitResumeRequired
        guard nativeFailure else {
            audioLifecycle.updateRuntimePlayout(isReady: false)
            return false
        }

        let message: String
        if diagnostics.unexpectedRecordingRequestCount > 0 || diagnostics.inputBusEnabled {
            message = "The iPhone refused audio because the route tried to use a call-style input path."
        } else if !diagnostics.categoryIsMediaPlayback
            || !diagnostics.modeIsDefault
            || diagnostics.outputChannelCount != 2
            || abs(diagnostics.sampleRate - 48_000) >= 1 {
            message = "The iPhone refused a degraded call-quality audio route. End the phone or FaceTime call, then retry audio."
        } else {
            message = "The iPhone full-quality stereo output could not start."
        }
        let diagnostic = diagnostics.failureMessage
            ?? "RemoteIO failure=\(diagnostics.failureCode), status=\(diagnostics.lastLifecycleStatus), renderStatus=\(diagnostics.lastPlayoutStatus), callbacks=\(diagnostics.playoutCallbackCount), failures=\(diagnostics.playoutFailureCount), recordRequests=\(diagnostics.unexpectedRecordingRequestCount)."
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            failureMessage: message,
            diagnostic: diagnostic
        )
        return true
    }

    private func handleControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    ) async {
        // An Active acknowledgement without a currently accepted Show must never reinstall
        // capability or focus. Keep processing the metadata with its authorization revoked:
        // an Active-for-Hide acknowledgement must fail the Hide immediately rather than wait for
        // its timeout, and an extremely early acknowledgement must remain correlatable by ID.
        let safeInputAuthorization: WebRTCInputAuthorization?
        if acknowledgement.state == .active,
           !acceptsActiveScreenAcknowledgement {
            remoteHideRequired = true
            inputAuthorization?.revoke()
            safeInputAuthorization = nil
        } else {
            safeInputAuthorization = inputAuthorization
        }
        if pendingRecoveryProbe?.requestID == acknowledgement.id {
            await completeRecoveryProbe(
                with: acknowledgement,
                inputAuthorization: safeInputAuthorization
            )
            return
        }

        guard let pending = pendingScreenVisibilityRequest else {
            cacheEarlyControlAcknowledgement(
                acknowledgement,
                inputAuthorization: safeInputAuthorization
            )
            return
        }
        guard pending.sessionGeneration == sessionGeneration,
              pending.operationGeneration == screenVisibilityOperationGeneration,
              pending.id == acknowledgement.id else {
            cacheEarlyControlAcknowledgement(
                acknowledgement,
                inputAuthorization: safeInputAuthorization
            )
            return
        }

        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        pendingScreenVisibilityRequest = nil
        let reachedTarget = applyControlAcknowledgement(
            acknowledgement,
            inputAuthorization: safeInputAuthorization,
            requestedVisibility: pending.isVisible
        )
        pending.continuation.resume(returning: reachedTarget)
    }

    private func cacheEarlyControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    ) {
        // A local actor hop can let an extremely fast acknowledgement arrive before the caller
        // installs either its UI continuation or the exact recovery-probe ID.
        if let replaced = earlyControlAcknowledgements.updateValue(
            ReceivedControlAcknowledgement(
                acknowledgement: acknowledgement,
                inputAuthorization: inputAuthorization
            ),
            forKey: acknowledgement.id
        ) {
            replaced.inputAuthorization?.revoke()
        }
        if earlyControlAcknowledgements.count > 4,
           let oldest = earlyControlAcknowledgements.keys.min() {
            earlyControlAcknowledgements.removeValue(forKey: oldest)?
                .inputAuthorization?.revoke()
        }
    }

    private func sendRecoveryProbe(
        peer: WebRTCPeer,
        generation: UUID,
        epoch: UInt64
    ) async {
        guard generation == sessionGeneration,
              self.peer === peer,
              recoveryProofRequired,
              epoch == recoveryProofEpoch else {
            return
        }

        pendingRecoveryProbe = PendingRecoveryProbe(
            sessionGeneration: generation,
            epoch: epoch,
            requestID: nil
        )
        do {
            let requestID = try await peer.setScreenVisible(false)
            guard generation == sessionGeneration,
                  self.peer === peer,
                  recoveryProofRequired,
                  epoch == recoveryProofEpoch,
                  pendingRecoveryProbe?.sessionGeneration == generation,
                  pendingRecoveryProbe?.epoch == epoch else {
                return
            }
            pendingRecoveryProbe = PendingRecoveryProbe(
                sessionGeneration: generation,
                epoch: epoch,
                requestID: requestID
            )
            if let received = earlyControlAcknowledgements.removeValue(
                forKey: requestID
            ) {
                await completeRecoveryProbe(
                    with: received.acknowledgement,
                    inputAuthorization: received.inputAuthorization
                )
            }
        } catch {
            if pendingRecoveryProbe?.sessionGeneration == generation,
               pendingRecoveryProbe?.epoch == epoch {
                pendingRecoveryProbe = nil
            }
            // The coordinator owns bounded retry/exhaustion. A failed probe must not convert an
            // otherwise-live WSS session into an immediate terminal error.
        }
    }

    private func completeRecoveryProbe(
        with acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    ) async {
        // A recovery proof is always Hide/Inactive and therefore must never retain input.
        inputAuthorization?.revoke()
        guard let probe = pendingRecoveryProbe,
              let requestID = probe.requestID,
              probe.sessionGeneration == sessionGeneration,
              probe.epoch == recoveryProofEpoch,
              requestID == acknowledgement.id,
              acknowledgement.state == .inactive,
              recoveryProofRequired else {
            return
        }

        pendingRecoveryProbe = nil
        restartAnswerAwaitingSendEpoch = nil
        recoveryProofRequired = false
        iceIsConnected = true
        isPeerConnected = true
        isControlChannelReady = true
        isConnecting = false
        isScreenVisible = false
        remoteHideRequired = false
        invalidateRemoteInputState()
        stateText = "Connected"
        // The authenticated, current-generation inactive acknowledgement is the recovery proof
        // that permits remote audio to leave the fail-closed mute gate.
        audioLifecycle.transportBecameHealthy()
        await recoveryCoordinator?.iceStateChanged(.connected)
    }

    @discardableResult
    private func applyControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        requestedVisibility: Bool
    ) -> Bool {
        let acknowledgedActive = acknowledgement.state == .active
        let isActive = acknowledgedActive && canViewScreen
        let mayAcceptActive = requestedVisibility && acceptsActiveScreenAcknowledgement
        isScreenVisible = isActive && mayAcceptActive
        if isActive && mayAcceptActive {
            remoteHideRequired = true
            installRemoteInputCapability(
                acknowledgement.inputCapability,
                authorization: inputAuthorization
            )
            stateText = "Screen live"
        } else if isPeerConnected {
            acceptsActiveScreenAcknowledgement = false
            remoteHideRequired = acknowledgedActive
            inputAuthorization?.revoke()
            invalidateRemoteInputState()
            stateText = "Connected"
        } else {
            acceptsActiveScreenAcknowledgement = false
            remoteHideRequired = acknowledgedActive
            inputAuthorization?.revoke()
            invalidateRemoteInputState()
        }

        let reachedTarget = Self.acknowledgementReachedVisibilityTarget(
            acknowledgement.state,
            requestedVisibility: requestedVisibility,
            mayAcceptActive: mayAcceptActive,
            canViewScreen: canViewScreen
        )
        if !reachedTarget, requestedVisibility {
            lastError = "The Mac could not start screen capture. Check Screen Recording permission."
        }
        return reachedTarget
    }

    static func acknowledgementReachedVisibilityTarget(
        _ state: WebRTCScreenState,
        requestedVisibility: Bool,
        mayAcceptActive: Bool,
        canViewScreen: Bool
    ) -> Bool {
        if requestedVisibility {
            return state == .active && mayAcceptActive && canViewScreen
        }
        // A Hide is successful only when the host explicitly confirms Inactive. In particular,
        // losing local transport readiness cannot reinterpret an Active acknowledgement as safe.
        return state == .inactive
    }

    private func installRemoteInputCapability(
        _ capability: WebRTCInputCapability?,
        authorization: WebRTCInputAuthorization?
    ) {
        invalidateRemoteInputState()
        guard let capability,
              let authorization,
              authorization.isValid else {
            authorization?.revoke()
            return
        }
        remoteInputCapability = capability
        remoteInputAuthorization = authorization
    }

    private func handleRemoteInputFeedback(_ feedback: WebRTCInputFeedback) {
        guard let capability = remoteInputCapability,
              feedback.screenRequestID == capability.screenRequestID,
              feedback.inputSessionID == capability.inputSessionID else {
            invalidateRemoteInputState()
            return
        }

        guard let pending = pendingRemoteInputs.removeValue(forKey: feedback.id) else {
            guard earlyRemoteInputFeedback.count < 32 else {
                lastDiagnostic = "Remote input feedback arrived out of bounds."
                invalidateRemoteInputState()
                return
            }
            earlyRemoteInputFeedback[feedback.id] = feedback
            return
        }
        if let index = pendingRemoteInputOrder.firstIndex(of: feedback.id) {
            pendingRemoteInputOrder.remove(at: index)
        }

        guard feedback.result == .accepted else {
            clearRemoteKeyboardFocus()
            handleRemoteInputRejection(feedback.rejectionReason)
            return
        }

        switch pending.kind {
        case .pointer:
            guard pending.pointerIntentID == latestPointerIntentID else { return }
            applyRemoteInputFocus(feedback.focus)

        case .keyboard(let generation):
            guard focusedInputGeneration == generation else { return }
            applyRemoteInputFocus(feedback.focus)
        }
    }

    private func handleRemoteInputRejection(_ reason: WebRTCInputRejectionReason?) {
        switch reason {
        case .accessibilityPermissionRequired:
            lastError = "Remote control needs Accessibility permission on the Mac."
            invalidateRemoteInputState()
        case .eventPostingPermissionRequired:
            lastError = "The Mac has not allowed AudioStreamer to post mouse and keyboard events."
            invalidateRemoteInputState()
        case .inputDisabled:
            lastError = "Remote control is disabled on the Mac."
            invalidateRemoteInputState()
        case .staleSession:
            invalidateRemoteInputState()
        case .rateLimited:
            lastDiagnostic = "Remote input was rate-limited; tap the field again before typing."
        case .injectionFailed:
            lastError = "The Mac could not post that remote input event."
        case .invalidRequest:
            lastDiagnostic = "The Mac rejected an invalid remote input action."
        case .invalidFocus:
            lastDiagnostic = "Mac focus changed; tap the field again before typing."
        case nil:
            invalidateRemoteInputState()
        }
    }

    private func applyRemoteInputFocus(_ focus: WebRTCInputFocus) {
        guard let generation = Self.remoteKeyboardGeneration(for: focus) else {
            if case .editable(_, secure: true) = focus {
                lastDiagnostic = "Secure Mac text fields stay local and cannot receive remote typing."
            }
            clearRemoteKeyboardFocus()
            return
        }
        focusedInputGeneration = generation
        focusedInputIsSecure = false
    }

    /// A second, viewer-side fail-closed boundary for older or compromised hosts.
    /// The current Mac host never advertises editable focus for secure AX controls.
    static func remoteKeyboardGeneration(for focus: WebRTCInputFocus) -> UInt64? {
        guard case .editable(let generation, secure: false) = focus else { return nil }
        return generation
    }

    private func clearRemoteKeyboardFocus() {
        focusedInputGeneration = nil
        focusedInputIsSecure = false
    }

    private func invalidateRemoteInputState() {
        // Revoke the exact peer-shared send gate before cancelling actor work. A send already
        // inside the gate linearizes before this call; a queued send cannot enter afterward.
        remoteInputAuthorization?.revoke()
        remoteInputAuthorization = nil
        remoteInputGeneration = UUID()
        remoteInputDrainTask?.cancel()
        remoteInputDrainTask = nil
        remoteInputQueue.removeAll(keepingCapacity: false)
        pendingRemoteInputs.removeAll(keepingCapacity: false)
        pendingRemoteInputOrder.removeAll(keepingCapacity: false)
        earlyRemoteInputFeedback.removeAll(keepingCapacity: false)
        latestPointerIntentID = 0
        remoteInputCapability = nil
        clearRemoteKeyboardFocus()
    }

    #if DEBUG
    /// Installs non-sensitive synthetic state for lifecycle ordering tests only. Release builds
    /// contain neither this hook nor the snapshot type.
    @discardableResult
    func debugInstallQueuedReturnForPassiveTeardown(
        focusGeneration: UInt64 = 41
    ) -> WebRTCInputAuthorization {
        invalidateRemoteInputState()
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 73
        )
        let authorization = WebRTCInputAuthorization()
        remoteInputCapability = capability
        remoteInputAuthorization = authorization
        focusedInputGeneration = focusGeneration
        focusedInputIsSecure = false
        isPeerConnected = true
        iceIsConnected = true
        isControlChannelReady = true
        isScreenVisible = true
        acceptsActiveScreenAcknowledgement = true
        remoteHideRequired = true
        remoteInputQueue = [
            QueuedRemoteInput(
                action: .returnKey(focusGeneration: focusGeneration),
                capability: capability,
                authorization: authorization,
                sessionGeneration: sessionGeneration,
                inputGeneration: remoteInputGeneration,
                pointerIntentID: nil
            )
        ]
        return authorization
    }

    var debugRemoteInputState: WorldwideRemoteInputDebugState {
        WorldwideRemoteInputDebugState(
            capabilityInstalled: remoteInputCapability != nil,
            authorizationInstalled: remoteInputAuthorization != nil,
            focusGeneration: focusedInputGeneration,
            queuedActionCount: remoteInputQueue.count,
            pendingActionCount: pendingRemoteInputs.count,
            inputGeneration: remoteInputGeneration,
            inputAvailable: isRemoteInputAvailable,
            acceptsActiveScreenAcknowledgement: acceptsActiveScreenAcknowledgement,
            remoteHideRequired: remoteHideRequired,
            hideRequestWouldBeNoOp: visibilityRequestCanReuseCurrentState(false),
            screenVisibilityOperationGeneration: screenVisibilityOperationGeneration
        )
    }

    @discardableResult
    func debugDeliverLateActiveAcknowledgement() async -> WebRTCInputAuthorization {
        let authorization = WebRTCInputAuthorization()
        await handleControlAcknowledgement(
            WebRTCControlAcknowledgement(
                id: 74,
                state: .active,
                inputCapability: WebRTCInputCapability(
                    inputSessionID: UUID(),
                    screenRequestID: 74
                )
            ),
            inputAuthorization: authorization
        )
        return authorization
    }

    func debugSimulateLocallyHiddenPendingShow() {
        isScreenVisible = false
    }

    func debugInstallScreenVisibilityRequestSender(
        _ sender: @escaping @MainActor (Bool) async throws -> UInt64
    ) {
        precondition(peer == nil)
        debugScreenVisibilityRequestSender = sender
    }

    func debugDeliverControlAcknowledgement(
        id: UInt64,
        state: WebRTCScreenState
    ) async {
        await handleControlAcknowledgement(
            WebRTCControlAcknowledgement(id: id, state: state),
            inputAuthorization: nil
        )
    }
    #endif

    private func clearEarlyControlAcknowledgements() {
        for received in earlyControlAcknowledgements.values {
            received.inputAuthorization?.revoke()
        }
        earlyControlAcknowledgements.removeAll(keepingCapacity: false)
    }

    private func completePendingScreenVisibilityRequest(success: Bool) {
        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        guard let pending = pendingScreenVisibilityRequest else { return }
        pendingScreenVisibilityRequest = nil
        pending.continuation.resume(returning: success)
    }

    private func controlAcknowledgementTimedOut(
        requestID: UInt64,
        generation: UUID,
        operationGeneration: UUID
    ) {
        guard generation == sessionGeneration,
              operationGeneration == screenVisibilityOperationGeneration,
              pendingScreenVisibilityRequest?.sessionGeneration == generation,
              pendingScreenVisibilityRequest?.operationGeneration == operationGeneration,
              pendingScreenVisibilityRequest?.id == requestID else {
            return
        }
        completePendingScreenVisibilityRequest(success: false)
        failSession(
            "The Mac did not confirm the screen state, so the session was closed for privacy.",
            generation: generation
        )
    }

    private func markViewerTransportHealthyIfPossible(
        _ state: WebRTCICEState
    ) async {
        guard !recoveryProofRequired,
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady else {
            if recoveryProofRequired {
                stateText = "Recovering secure media"
            }
            return
        }
        isConnecting = false
        if !isScreenVisible {
            stateText = "Connected"
        }
        audioLifecycle.transportBecameHealthy()
        await recoveryCoordinator?.iceStateChanged(state)
    }

    private func markTransportUncertain(
        _ state: String,
        requiresProof: Bool = false
    ) {
        audioLifecycle.transportBecameUncertain()
        acceptsActiveScreenAcknowledgement = false
        remoteHideRequired = false
        screenVisibilityOperationGeneration = UUID()
        invalidateRemoteInputState()
        let answerWasAwaitingSend = restartAnswerAwaitingSendEpoch != nil
        if let requestID = pendingRecoveryProbe?.requestID {
            earlyControlAcknowledgements.removeValue(forKey: requestID)?
                .inputAuthorization?.revoke()
        }
        recoveryProofEpoch &+= 1
        recoveryProofRequired = recoveryProofRequired || requiresProof
        pendingRecoveryProbe = nil
        restartAnswerAwaitingSendEpoch = answerWasAwaitingSend
            ? recoveryProofEpoch
            : nil
        completePendingScreenVisibilityRequest(success: false)
        iceIsConnected = false
        isScreenVisible = false
        stateText = state
    }

    private func hideScreenForPassiveLifecycleIfNeeded() {
        let needsRemoteHide = isScreenVisible
            || pendingScreenVisibilityRequest?.isVisible == true
            || acceptsActiveScreenAcknowledgement
        guard needsRemoteHide else {
            suspendRemoteInputPresentation()
            return
        }
        beginPassiveScreenTeardown()
    }

    private func sendICERestartRequest(
        client: RendezvousSignalingClient,
        generation: UUID
    ) async throws {
        guard generation == sessionGeneration,
              signaling === client,
              nextICERestartRequestID < UInt64.max else {
            throw WorldwideSessionError.restartUnavailable
        }

        markTransportUncertain("Recovering secure media", requiresProof: true)
        let requestID = nextICERestartRequestID
        nextICERestartRequestID += 1
        try await client.send(.iceRestartRequest(.init(requestID: requestID)))
    }

    private func iceRecoveryDidExhaust(generation: UUID) {
        guard generation == sessionGeneration,
              recoveryProofRequired || !iceIsConnected,
              hasActiveSession else {
            return
        }
        failSession(
            "The direct media route could not be recovered while signaling remained connected.",
            generation: generation
        )
    }

    static func rendezvousEndpoint(debugOverride: String?) -> URL? {
        #if DEBUG
        if let debugOverride,
           let endpoint = validEndpoint(debugOverride) {
            return endpoint
        }
        #endif

        guard let configured = Bundle.main.object(
            forInfoDictionaryKey: "AudioStreamerRendezvousURL"
        ) as? String else {
            return nil
        }
        return validEndpoint(configured)
    }

    private static func validEndpoint(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              let url = URL(string: trimmed) else {
            return nil
        }
        return url
    }
}

private struct PendingScreenVisibilityRequest {
    let id: UInt64
    let isVisible: Bool
    let sessionGeneration: UUID
    let operationGeneration: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

#if DEBUG
struct WorldwideRemoteInputDebugState: Equatable {
    let capabilityInstalled: Bool
    let authorizationInstalled: Bool
    let focusGeneration: UInt64?
    let queuedActionCount: Int
    let pendingActionCount: Int
    let inputGeneration: UUID
    let inputAvailable: Bool
    let acceptsActiveScreenAcknowledgement: Bool
    let remoteHideRequired: Bool
    let hideRequestWouldBeNoOp: Bool
    let screenVisibilityOperationGeneration: UUID
}
#endif

private struct ReceivedControlAcknowledgement {
    let acknowledgement: WebRTCControlAcknowledgement
    let inputAuthorization: WebRTCInputAuthorization?
}

private struct PendingRecoveryProbe {
    let sessionGeneration: UUID
    let epoch: UInt64
    let requestID: UInt64?
}

private struct QueuedRemoteInput {
    let action: WebRTCInputAction
    let capability: WebRTCInputCapability
    let authorization: WebRTCInputAuthorization
    let sessionGeneration: UUID
    let inputGeneration: UUID
    let pointerIntentID: UInt64?
}

private extension WebRTCInputAction {
    var requiresRemoteFocus: Bool {
        switch self {
        case .tap, .primaryDrag:
            false
        case .insertText, .backspace, .returnKey:
            true
        }
    }
}

private struct PendingRemoteInput {
    // Never retain committed text while waiting for host feedback. The full action exists only
    // in the bounded pre-send queue and the native send window; correlation needs this metadata.
    let kind: PendingRemoteInputKind
    let pointerIntentID: UInt64?
}

enum PendingRemoteInputKind: Equatable {
    case pointer
    case keyboard(focusGeneration: UInt64)

    init(_ action: WebRTCInputAction) {
        switch action {
        case .tap, .primaryDrag:
            self = .pointer
        case .insertText(_, let focusGeneration),
             .backspace(let focusGeneration),
             .returnKey(let focusGeneration):
            self = .keyboard(focusGeneration: focusGeneration)
        }
    }
}

private enum WorldwideSessionError: Error, LocalizedError {
    case signalBeforeReady
    case macDisconnected
    case restartUnavailable
    case screenControlUnavailable
    case server(RendezvousServerError)

    var errorDescription: String? {
        switch self {
        case .signalBeforeReady:
            "The service sent media setup before the secure session was ready."
        case .macDisconnected:
            "The Mac disconnected. Generate a new one-time invitation to reconnect."
        case .restartUnavailable:
            "The secure media recovery request could not be sent for this session."
        case .screenControlUnavailable:
            "The secure screen-control channel is unavailable."
        case .server(let error):
            switch error {
            case .peerUnavailable:
                "The Mac is not available for this invitation."
            case .rateLimited:
                "Too many connection attempts. Wait briefly and try again."
            case .invitationUnavailable:
                "This invitation has already been used or is unavailable."
            case .invitationExpired:
                "This invitation expired. Generate a new one on the Mac."
            case .roleConflict:
                "Another iPhone already claimed this invitation."
            case .requestRejected:
                "The rendezvous service rejected the connection."
            }
        }
    }
}

private extension WebRTCICEState {
    var displayText: String {
        switch self {
        case .new: "New"
        case .checking: "Checking"
        case .connected: "Connected"
        case .completed: "Complete"
        case .disconnected: "Interrupted"
        case .failed: "Failed"
        case .closed: "Closed"
        case .unknown: "Unknown"
        }
    }
}

private extension WebRTCICERouteKind {
    var displayText: String {
        switch self {
        case .direct: "Direct"
        case .relayed: "TURN relay"
        case .unknown: "Unknown"
        }
    }
}
