import AudioToolbox
import CoreGraphics
import Foundation
import RemoteSessionCore
import WebRTCTransport

struct WorldwideScreenPresentationLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UUID

    init(id: UUID = UUID(), sessionGeneration: UUID) {
        self.id = id
        self.sessionGeneration = sessionGeneration
    }
}

struct WorldwideScreenVisibilityRequestKey: Hashable, Sendable {
    let sessionGeneration: UUID
    let requestID: UInt64
}

#if DEBUG
struct WorldwideScreenVisibilityDebugRequest {
    let lease: WorldwideScreenPresentationLease
    let operationID: UUID
    let isVisible: Bool
    let expectedPeer: WebRTCPeer?
}

struct WorldwideScreenVisibilityPostSendDebugEvent {
    let request: WorldwideScreenVisibilityDebugRequest
    let requestID: UInt64
}

struct WorldwideScreenPresentationDebugState {
    let sessionGeneration: UUID
    let currentLease: WorldwideScreenPresentationLease?
    let activeLease: WorldwideScreenPresentationLease?
    let isScreenVisible: Bool
    let inputAvailable: Bool
    let remoteHideRequired: Bool
    let pendingRequestKey: WorldwideScreenVisibilityRequestKey?
    let displacedPendingRequestCount: Int
    let hasActiveSession: Bool
}

struct WorldwideScreenPresentationDebugFixture {
    let lease: WorldwideScreenPresentationLease
    let authorization: WebRTCInputAuthorization
}

struct WorldwideIOSPlayoutProofDebugHandle: Equatable, Sendable {
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let sessionGeneration: UUID
}

enum WorldwideIOSPlayoutProofDebugSource: Sendable {
    case polling
    case statistics
}

enum WorldwideIOSPlayoutProofDebugStage: Equatable, Sendable {
    case awaitingInitialFloor
    case awaitingRecoveryAuthorization
    case awaitingPostRecoveryFloor
    case awaitingFreshEvidence
}

struct WorldwideIOSPlayoutProofDebugState: Equatable, Sendable {
    let handle: WorldwideIOSPlayoutProofDebugHandle?
    let stage: WorldwideIOSPlayoutProofDebugStage?
    let callbackFloor: UInt64?
    let frameFloor: UInt64?
    let permittedFailureFloor: UInt64?
    let lastCallbackCount: UInt64?
    let lastFrameCount: UInt64?
    let lastFailureCount: UInt64?
    let recoveryAuthorizationIdentity: ObjectIdentifier?
    let recoveryAuthorizationIsValid: Bool
}
#endif

private enum IOSPlayoutProofStage {
    case awaitingRecoveryBaseline
    case awaitingInitialFloor
    case awaitingRecoveryAuthorization
    case awaitingPostRecoveryFloor
    case awaitingFreshEvidence
}

private struct IOSPlayoutRecoveryBaseline {
    let callbackCount: UInt64
    let frameCount: UInt64
    let failureCount: UInt64
}

private final class IOSPlayoutProofAttempt {
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let sessionGeneration: UUID
    let expectedPeer: WebRTCPeer?
    var stage: IOSPlayoutProofStage
    var recoveryAuthorization: WebRTCIOSPlayoutRecoveryAuthorization?
    /// Exact pre-request lifetime-cumulative snapshot; never post-request live observation.
    private(set) var recoveryBaseline: IOSPlayoutRecoveryBaseline?
    var callbackFloor: UInt64?
    var frameFloor: UInt64?
    var lastCallbackCount: UInt64?
    var lastFrameCount: UInt64?
    var lastFailureCount: UInt64?

    var permittedFailureFloor: UInt64 {
        recoveryBaseline?.failureCount ?? 0
    }

    init(
        proofAttemptID: UUID = UUID(),
        counterWindowID: UUID = UUID(),
        sessionGeneration: UUID,
        expectedPeer: WebRTCPeer?,
        stage: IOSPlayoutProofStage
    ) {
        self.proofAttemptID = proofAttemptID
        self.counterWindowID = counterWindowID
        self.sessionGeneration = sessionGeneration
        self.expectedPeer = expectedPeer
        self.stage = stage
    }

    func captureRecoveryBaseline(
        callbackCount: UInt64,
        frameCount: UInt64,
        failureCount: UInt64
    ) {
        precondition(stage == .awaitingRecoveryBaseline)
        precondition(recoveryAuthorization == nil)
        precondition(recoveryBaseline == nil)
        precondition(callbackFloor == nil && frameFloor == nil)
        precondition(
            lastCallbackCount == nil
                && lastFrameCount == nil
                && lastFailureCount == nil
        )
        recoveryBaseline = IOSPlayoutRecoveryBaseline(
            callbackCount: callbackCount,
            frameCount: frameCount,
            failureCount: failureCount
        )
    }
}

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
    @Published private(set) var screenAcknowledgementOracle:
        WorldwideScreenAcknowledgementOracleSnapshot?
    @Published private(set) var audioStateText = "Inactive"
    @Published private(set) var isRemoteAudioAvailable = false
    @Published private(set) var isRemoteAudioPlaying = false
    @Published private(set) var audioPlayoutOracle: WorldwideAudioPlayoutOracleSnapshot?
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
    private var audioPlayoutProofTimeoutTask: Task<Void, Never>?
    private var audioPlayoutRecoveryAuthorization: WebRTCIOSPlayoutRecoveryAuthorization?
    private var iosPlayoutProofAttempt: IOSPlayoutProofAttempt?
    private var controlAcknowledgementTimeoutTask: Task<Void, Never>?
    private var pendingScreenVisibilityRequest: PendingScreenVisibilityRequest?
    private var earlyControlAcknowledgements: [
        WorldwideScreenVisibilityRequestKey: ReceivedControlAcknowledgement
    ] = [:]
    private var retiredScreenVisibilityRequestKeys: Set<
        WorldwideScreenVisibilityRequestKey
    > = []
    private var retiredScreenVisibilityRequestOrder: [
        WorldwideScreenVisibilityRequestKey
    ] = []
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
    private var currentScreenPresentationLease: WorldwideScreenPresentationLease?
    private var activeScreenPresentationLease: WorldwideScreenPresentationLease?
    private var remoteScreenOwnerLease: WorldwideScreenPresentationLease?
    private var screenTeardownOperationByLeaseID: [UUID: UUID] = [:]
    private var screenShowOperationByLeaseID: [UUID: UUID] = [:]
    private var screenVisibilityQueue: [QueuedScreenVisibilityOperation] = []
    private var screenVisibilityDrainTask: Task<Void, Never>?
    private var screenVisibilityQueueGeneration = UUID()
    private var acceptsActiveScreenAcknowledgement = false
    private var remoteHideRequired = false
    private var screenVisibilityOperationGeneration = UUID()
    #if DEBUG
    private var debugScreenVisibilityRequestSender: (@MainActor (Bool) async throws -> UInt64)?
    private var debugScreenVisibilityRequestSenderV2: (
        @MainActor (WorldwideScreenVisibilityDebugRequest) async throws -> UInt64
    )?
    private var debugScreenVisibilityPostSendHook: (
        @MainActor (WorldwideScreenVisibilityPostSendDebugEvent) async -> Void
    )?
    private var debugCurrentScreenPresentationLease: WorldwideScreenPresentationLease?
    private var debugActiveScreenPresentationLease: WorldwideScreenPresentationLease?
    private var debugStatisticsStarter: (@MainActor (WebRTCPeer) async throws -> Void)?
    private var debugSessionRunner: (@MainActor () async -> Void)?
    private var debugIOSPlayoutDiagnosticsReader: (
        @MainActor (WebRTCPeer) async -> WebRTCIOSPlayoutDiagnostics?
    )?
    private var debugIOSPlayoutRecoveryRequester: (
        @MainActor (WebRTCPeer, WebRTCIOSPlayoutRecoveryAuthorization) async -> Void
    )?
    private var debugIOSPlayoutRecoveryPendingObserver: (@MainActor () -> Void)?
    private var debugPendingScreenVisibilityWaiters: [
        WorldwideScreenVisibilityRequestKey: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var debugProcessedScreenVisibilityPostSendOperationIDs: Set<UUID> = []
    private var debugScreenVisibilityPostSendProcessingWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var debugDisplacedPendingScreenVisibilityRequests: [
        PendingScreenVisibilityRequest
    ] = []
    private var debugRemoteInputSender: (
        @MainActor (
            WebRTCPeer,
            WebRTCInputAction,
            WebRTCInputCapability,
            WebRTCInputAuthorization
        ) async throws -> UInt64
    )?
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

    /// Retires terminal presentation from an earlier media session before the coordinator starts
    /// a new pairing/reconnect attempt. Passive scene lifecycle changes intentionally do not call
    /// this method, so backgrounding alone cannot rewrite a real terminal outcome.
    func beginFreshConnectionAttempt() {
        guard !hasActiveSession else { return }
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

    func issueScreenPresentationLease() -> WorldwideScreenPresentationLease? {
        guard canViewScreen else { return nil }

        let lease = WorldwideScreenPresentationLease(sessionGeneration: sessionGeneration)
        let replacedLease = currentScreenPresentationLease
        currentScreenPresentationLease = lease
        #if DEBUG
        debugCurrentScreenPresentationLease = lease
        #endif

        guard let replacedLease, replacedLease != lease else {
            revokeScreenPresentationLocally(for: lease, clearActiveOwnership: false)
            return lease
        }

        revokeScreenPresentationLocally(for: replacedLease, clearActiveOwnership: false)
        let needsRemoteHide = replacedLease.sessionGeneration == sessionGeneration
            && screenPresentationNeedsRemoteHide(replacedLease)
        supersedeScreenShow(for: replacedLease)
        if needsRemoteHide {
            _ = claimScreenTeardown(
                for: replacedLease,
                allowSupersededSameSessionLease: true,
                completion: nil
            )
        }
        return lease
    }

    func screenPresentationIsCurrent(_ lease: WorldwideScreenPresentationLease) -> Bool {
        lease.sessionGeneration == sessionGeneration
            && currentScreenPresentationLease == lease
    }

    func screenPresentationIsVisible(_ lease: WorldwideScreenPresentationLease) -> Bool {
        screenPresentationIsCurrent(lease)
            && activeScreenPresentationLease == lease
            && isScreenVisible
    }

    func remoteInputIsAvailable(for lease: WorldwideScreenPresentationLease) -> Bool {
        screenPresentationIsVisible(lease) && isRemoteInputAvailable
    }

    func retireScreenPresentationLease(_ lease: WorldwideScreenPresentationLease) {
        guard currentScreenPresentationLease == lease else { return }
        revokeScreenPresentationLocally(for: lease, clearActiveOwnership: false)
        currentScreenPresentationLease = nil
        #if DEBUG
        if debugCurrentScreenPresentationLease == lease {
            debugCurrentScreenPresentationLease = nil
        }
        #endif
    }

    @discardableResult
    func setScreenVisible(
        _ visible: Bool,
        for lease: WorldwideScreenPresentationLease
    ) async -> Bool {
        if visible {
            guard screenPresentationIsCurrent(lease) else { return false }
            if screenPresentationIsVisible(lease),
               screenShowOperationByLeaseID[lease.id] == nil {
                return true
            }
            let operationID = UUID()
            screenShowOperationByLeaseID[lease.id] = operationID
            return await withCheckedContinuation { continuation in
                enqueueScreenVisibilityOperation(
                    lease: lease,
                    operationID: operationID,
                    isVisible: true,
                    completion: { continuation.resume(returning: $0) }
                )
            }
        }

        return await withCheckedContinuation { continuation in
            let claimed = claimScreenTeardown(
                for: lease,
                allowSupersededSameSessionLease: false,
                completion: { continuation.resume(returning: $0) }
            )
            if !claimed {
                continuation.resume(returning: false)
            }
        }
    }

    @discardableResult
    func beginPassiveScreenTeardown(
        for lease: WorldwideScreenPresentationLease,
        completion: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        claimScreenTeardown(
            for: lease,
            allowSupersededSameSessionLease: false,
            completion: { _ in completion() }
        )
    }

    /// Immediately closes the local input gate before UI code starts an asynchronous Hide.
    func suspendRemoteInputPresentation() {
        invalidateRemoteInputState()
    }

    func beginPassiveScreenTeardown() {
        guard let lease = currentScreenPresentationLease ?? legacyScreenPresentationLease() else {
            suspendRemoteInputPresentation()
            return
        }
        _ = beginPassiveScreenTeardown(for: lease)
    }

    /// Retained only as a deterministic ordering seam for the pre-existing lifecycle test.
    func beginPassiveScreenTeardown(
        hideOperation: @escaping @MainActor () async -> Void
    ) {
        if let lease = currentScreenPresentationLease ?? legacyScreenPresentationLease() {
            revokeScreenPresentationLocally(for: lease, clearActiveOwnership: false)
        } else {
            suspendRemoteInputPresentation()
        }
        screenVisibilityOperationGeneration = UUID()
        completePendingScreenVisibilityRequest(success: false)
        Task { @MainActor in
            await hideOperation()
        }
    }

    @discardableResult
    func setScreenVisible(_ visible: Bool) async -> Bool {
        if visible {
            guard let lease = currentScreenPresentationLease
                ?? issueScreenPresentationLease() else {
                return false
            }
            return await setScreenVisible(true, for: lease)
        }
        guard let lease = currentScreenPresentationLease ?? legacyScreenPresentationLease() else {
            isScreenVisible = false
            invalidateRemoteInputState()
            return true
        }
        return await setScreenVisible(false, for: lease)
    }

    private func legacyScreenPresentationLease() -> WorldwideScreenPresentationLease? {
        guard canViewScreen || remoteHideRequired || isScreenVisible else { return nil }
        if let currentScreenPresentationLease {
            return currentScreenPresentationLease
        }
        let lease = WorldwideScreenPresentationLease(sessionGeneration: sessionGeneration)
        currentScreenPresentationLease = lease
        if isScreenVisible {
            activeScreenPresentationLease = lease
            remoteScreenOwnerLease = lease
        }
        #if DEBUG
        debugCurrentScreenPresentationLease = lease
        if isScreenVisible {
            debugActiveScreenPresentationLease = lease
        }
        #endif
        return lease
    }

    private func supersedeScreenShow(
        for lease: WorldwideScreenPresentationLease
    ) {
        guard lease.sessionGeneration == sessionGeneration else { return }
        if let pending = pendingScreenVisibilityRequest,
           pending.isVisible,
           pending.lease == lease {
            controlAcknowledgementTimeoutTask?.cancel()
            controlAcknowledgementTimeoutTask = nil
            pendingScreenVisibilityRequest = nil
            retireScreenVisibilityRequestKey(pending.key)
            pending.continuation.resume(returning: false)
        }
        screenShowOperationByLeaseID.removeValue(forKey: lease.id)
    }

    private func claimScreenTeardown(
        for lease: WorldwideScreenPresentationLease,
        allowSupersededSameSessionLease: Bool,
        completion: (@MainActor (Bool) -> Void)?
    ) -> Bool {
        guard lease.sessionGeneration == sessionGeneration else { return false }
        guard screenTeardownOperationByLeaseID[lease.id] == nil else { return false }
        guard allowSupersededSameSessionLease || currentScreenPresentationLease == lease else {
            return false
        }

        let operationID = UUID()
        screenTeardownOperationByLeaseID[lease.id] = operationID
        if currentScreenPresentationLease == lease {
            revokeScreenPresentationLocally(for: lease, clearActiveOwnership: false)
        }
        enqueueScreenVisibilityOperation(
            lease: lease,
            operationID: operationID,
            isVisible: false,
            completion: completion
        )
        return true
    }

    private func revokeScreenPresentationLocally(
        for lease: WorldwideScreenPresentationLease,
        clearActiveOwnership: Bool
    ) {
        guard lease.sessionGeneration == sessionGeneration else { return }
        if currentScreenPresentationLease == lease || activeScreenPresentationLease == lease {
            isScreenVisible = false
            acceptsActiveScreenAcknowledgement = false
            invalidateRemoteInputState()
        }
        if clearActiveOwnership, activeScreenPresentationLease == lease {
            activeScreenPresentationLease = nil
            #if DEBUG
            if debugActiveScreenPresentationLease == lease {
                debugActiveScreenPresentationLease = nil
            }
            #endif
        }
        remoteHideRequired = remoteScreenOwnerLease != nil
    }

    private func screenPresentationNeedsRemoteHide(
        _ lease: WorldwideScreenPresentationLease
    ) -> Bool {
        remoteScreenOwnerLease == lease
            || activeScreenPresentationLease == lease
            || pendingScreenVisibilityRequest?.lease == lease
            || screenShowOperationByLeaseID[lease.id] != nil
    }

    private func enqueueScreenVisibilityOperation(
        lease: WorldwideScreenPresentationLease,
        operationID: UUID,
        isVisible: Bool,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        let operation = QueuedScreenVisibilityOperation(
            lease: lease,
            operationID: operationID,
            isVisible: isVisible,
            sessionGeneration: lease.sessionGeneration,
            queueGeneration: screenVisibilityQueueGeneration,
            expectedPeer: peer,
            completion: completion
        )
        screenVisibilityQueue.append(operation)
        startScreenVisibilityDrainIfNeeded()
    }

    private func startScreenVisibilityDrainIfNeeded() {
        guard screenVisibilityDrainTask == nil else { return }
        let queueGeneration = screenVisibilityQueueGeneration
        screenVisibilityDrainTask = Task { [weak self] in
            await self?.drainScreenVisibilityQueue(queueGeneration: queueGeneration)
        }
    }

    private func drainScreenVisibilityQueue(queueGeneration: UUID) async {
        while queueGeneration == screenVisibilityQueueGeneration,
              !screenVisibilityQueue.isEmpty {
            let operation = screenVisibilityQueue.removeFirst()
            let reachedTarget = await performScreenVisibilityOperation(operation)
            operation.completion?(reachedTarget)
        }
        guard queueGeneration == screenVisibilityQueueGeneration else { return }
        screenVisibilityDrainTask = nil
        if !screenVisibilityQueue.isEmpty {
            startScreenVisibilityDrainIfNeeded()
        }
    }

    private func performScreenVisibilityOperation(
        _ operation: QueuedScreenVisibilityOperation
    ) async -> Bool {
        guard screenVisibilityOperationIsOwned(operation) else { return false }

        if operation.isVisible {
            guard currentScreenPresentationLease == operation.lease else {
                retireScreenVisibilityOperation(operation)
                return false
            }
            revokeScreenPresentationLocally(
                for: operation.lease,
                clearActiveOwnership: true
            )
        } else {
            revokeScreenPresentationLocally(
                for: operation.lease,
                clearActiveOwnership: false
            )
            if !screenPresentationNeedsRemoteHide(operation.lease) {
                retireScreenVisibilityOperation(operation)
                return true
            }
        }

        guard screenVisibilityTransportIsAvailable(operation.expectedPeer),
              canViewScreen else {
            let shouldFailClosed = !operation.isVisible
                && screenPresentationNeedsRemoteHide(operation.lease)
            if shouldFailClosed {
                failScreenVisibilityOperation(
                    operation,
                    message: "The Mac could not be told to stop screen sharing, so the session was closed for privacy."
                )
            } else {
                retireScreenVisibilityOperation(operation)
                if operation.isVisible,
                   screenVisibilityOperationIsSessionOwned(operation) {
                    lastError = "The secure screen-control channel is not ready yet."
                }
            }
            return false
        }

        screenVisibilityOperationGeneration = operation.operationID
        if operation.isVisible {
            acceptsActiveScreenAcknowledgement = true
            remoteScreenOwnerLease = operation.lease
            remoteHideRequired = true
        } else {
            acceptsActiveScreenAcknowledgement = false
        }

        do {
            guard screenVisibilityOperationIsOwned(operation) else { return false }
            let requestID = try await sendScreenVisibilityRequest(
                operation.isVisible,
                lease: operation.lease,
                operationID: operation.operationID,
                expectedPeer: operation.expectedPeer
            )
            #if DEBUG
            if let debugScreenVisibilityPostSendHook {
                await debugScreenVisibilityPostSendHook(
                    WorldwideScreenVisibilityPostSendDebugEvent(
                        request: WorldwideScreenVisibilityDebugRequest(
                            lease: operation.lease,
                            operationID: operation.operationID,
                            isVisible: operation.isVisible,
                            expectedPeer: operation.expectedPeer
                        ),
                        requestID: requestID
                    )
                )
            }
            #endif
            guard screenVisibilityOperationIsOwned(operation) else {
                retireScreenVisibilityRequestKey(
                    WorldwideScreenVisibilityRequestKey(
                        sessionGeneration: operation.sessionGeneration,
                        requestID: requestID
                    )
                )
                #if DEBUG
                notifyDebugScreenVisibilityPostSendProcessed(operation.operationID)
                #endif
                return false
            }
            #if DEBUG
            notifyDebugScreenVisibilityPostSendProcessed(operation.operationID)
            #endif

            let key = WorldwideScreenVisibilityRequestKey(
                sessionGeneration: operation.sessionGeneration,
                requestID: requestID
            )
            stateText = operation.isVisible
                ? "Starting Mac screen"
                : "Stopping Mac screen"

            let reachedTarget = await withCheckedContinuation { continuation in
                if let received = earlyControlAcknowledgements.removeValue(forKey: key) {
                    guard screenAcknowledgementPeer(
                        received.sourcePeer,
                        matches: operation.expectedPeer
                    ), screenVisibilityOperationIsOwned(operation) else {
                        received.inputAuthorization?.revoke()
                        retireScreenVisibilityRequestKey(key)
                        continuation.resume(returning: false)
                        return
                    }
                    let reachedTarget = applyControlAcknowledgement(
                        received.acknowledgement,
                        inputAuthorization: received.inputAuthorization,
                        pending: PendingScreenVisibilityRequest(
                            key: key,
                            isVisible: operation.isVisible,
                            lease: operation.lease,
                            operationID: operation.operationID,
                            sessionGeneration: operation.sessionGeneration,
                            queueGeneration: operation.queueGeneration,
                            expectedPeer: operation.expectedPeer,
                            continuation: continuation
                        )
                    )
                    retireScreenVisibilityRequestKey(key)
                    continuation.resume(returning: reachedTarget)
                    return
                }

                #if DEBUG
                installPendingScreenVisibilityRequest(
                    PendingScreenVisibilityRequest(
                        key: key,
                        isVisible: operation.isVisible,
                        lease: operation.lease,
                        operationID: operation.operationID,
                        sessionGeneration: operation.sessionGeneration,
                        queueGeneration: operation.queueGeneration,
                        expectedPeer: operation.expectedPeer,
                        continuation: continuation
                    )
                )
                notifyDebugPendingScreenVisibilityWaiters(key)
                #else
                pendingScreenVisibilityRequest = PendingScreenVisibilityRequest(
                    key: key,
                    isVisible: operation.isVisible,
                    lease: operation.lease,
                    operationID: operation.operationID,
                    sessionGeneration: operation.sessionGeneration,
                    queueGeneration: operation.queueGeneration,
                    expectedPeer: operation.expectedPeer,
                    continuation: continuation
                )
                #endif
                controlAcknowledgementTimeoutTask?.cancel()
                controlAcknowledgementTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    self?.controlAcknowledgementTimedOut(
                        key: key,
                        lease: operation.lease,
                        operationID: operation.operationID,
                        expectedPeer: operation.expectedPeer,
                        queueGeneration: operation.queueGeneration
                    )
                }
            }

            guard screenVisibilityOperationIsOwned(operation) else { return false }
            if !operation.isVisible, !reachedTarget {
                failScreenVisibilityOperation(
                    operation,
                    message: "The Mac did not confirm that screen sharing stopped, so the session was closed for privacy."
                )
                return false
            }
            retireScreenVisibilityOperation(operation)
            return reachedTarget
        } catch {
            guard screenVisibilityOperationIsOwned(operation) else { return false }
            if operation.isVisible {
                failScreenVisibilityOperation(
                    operation,
                    message: "The Mac could not confirm whether screen sharing started, so the session was closed for privacy."
                )
            } else {
                failScreenVisibilityOperation(
                    operation,
                    message: "The Mac could not be told to stop screen sharing, so the session was closed for privacy."
                )
            }
            return false
        }
    }

    private func screenVisibilityOperationIsSessionOwned(
        _ operation: QueuedScreenVisibilityOperation
    ) -> Bool {
        guard operation.sessionGeneration == sessionGeneration,
              operation.queueGeneration == screenVisibilityQueueGeneration else {
            return false
        }
        if let expectedPeer = operation.expectedPeer {
            return peer === expectedPeer
        }
        #if DEBUG
        return peer == nil
            && (debugScreenVisibilityRequestSender != nil
                || debugScreenVisibilityRequestSenderV2 != nil)
        #else
        return false
        #endif
    }

    private func screenVisibilityOperationIsOwned(
        _ operation: QueuedScreenVisibilityOperation
    ) -> Bool {
        guard screenVisibilityOperationIsSessionOwned(operation) else { return false }
        if operation.isVisible {
            return currentScreenPresentationLease == operation.lease
                && screenShowOperationByLeaseID[operation.lease.id] == operation.operationID
        }
        return screenTeardownOperationByLeaseID[operation.lease.id] == operation.operationID
    }

    private func retireScreenVisibilityOperation(
        _ operation: QueuedScreenVisibilityOperation
    ) {
        if operation.isVisible {
            if screenShowOperationByLeaseID[operation.lease.id] == operation.operationID {
                screenShowOperationByLeaseID.removeValue(forKey: operation.lease.id)
            }
        } else if screenTeardownOperationByLeaseID[operation.lease.id]
            == operation.operationID {
            screenTeardownOperationByLeaseID.removeValue(forKey: operation.lease.id)
        }
    }

    private func failScreenVisibilityOperation(
        _ operation: QueuedScreenVisibilityOperation,
        message: String
    ) {
        guard screenVisibilityOperationIsOwned(operation) else { return }
        failSession(message, generation: operation.sessionGeneration)
    }

    private func screenVisibilityTransportIsAvailable(_ expectedPeer: WebRTCPeer?) -> Bool {
        if expectedPeer != nil { return true }
        #if DEBUG
        return debugScreenVisibilityRequestSender != nil
            || debugScreenVisibilityRequestSenderV2 != nil
        #else
        return false
        #endif
    }

    private func sendScreenVisibilityRequest(
        _ visible: Bool,
        lease: WorldwideScreenPresentationLease,
        operationID: UUID,
        expectedPeer: WebRTCPeer?
    ) async throws -> UInt64 {
        #if DEBUG
        if let debugScreenVisibilityRequestSenderV2 {
            return try await debugScreenVisibilityRequestSenderV2(
                WorldwideScreenVisibilityDebugRequest(
                    lease: lease,
                    operationID: operationID,
                    isVisible: visible,
                    expectedPeer: expectedPeer
                )
            )
        }
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
                let requestID = try await sendRemoteInput(
                    queued.action,
                    peer: peer,
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
                // Actor sends are reentrant and may complete after this input generation was
                // revoked and a replacement capability was installed. An old failure must never
                // clear focus, diagnostics, authorization, or queued work belonging to the new
                // session. Treat loss of any exact ownership proof as a stale terminal return.
                guard !Task.isCancelled,
                      inputGeneration == remoteInputGeneration,
                      queued.sessionGeneration == sessionGeneration,
                      self.peer === peer,
                      queued.capability == remoteInputCapability,
                      queued.authorization === remoteInputAuthorization,
                      queued.authorization.isValid else {
                    return
                }
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

    private func sendRemoteInput(
        _ action: WebRTCInputAction,
        peer: WebRTCPeer,
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) async throws -> UInt64 {
        #if DEBUG
        if let debugRemoteInputSender {
            return try await debugRemoteInputSender(
                peer,
                action,
                capability,
                authorization
            )
        }
        #endif
        return try await peer.sendInput(
            action,
            capability: capability,
            authorization: authorization
        )
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

        #if DEBUG
        if let debugSessionRunner {
            await debugSessionRunner()
            return
        }
        #endif

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
            try await startStatistics(for: newPeer)
            // Statistics startup crosses the peer actor and is allowed to finish
            // non-cooperatively after disconnect or supersession. Re-prove every ownership
            // dimension before publishing negotiation state for this attempt.
            guard !Task.isCancelled,
                  generation == sessionGeneration,
                  signaling === client,
                  peer === newPeer else {
                return
            }
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

    private func startStatistics(for peer: WebRTCPeer) async throws {
        #if DEBUG
        if let debugStatisticsStarter {
            try await debugStatisticsStarter(peer)
            return
        }
        #endif
        try await peer.startStatistics()
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
                    peer: peer,
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
        peer sourcePeer: WebRTCPeer,
        signaling: RendezvousSignalingClient,
        generation: UUID
    ) async {
        guard generation == sessionGeneration,
              peer === sourcePeer else { return }

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
                inputAuthorization: inputAuthorization,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
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
            await refreshIOSPlayoutOracle(
                from: sourcePeer,
                generation: generation
            )
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
        retireIOSPlayoutRecoveryAttempt()
        audioLifecycle.stop()
        remoteAudioTrack = nil
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            clearRequestHistory: true
        )
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
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            clearRequestHistory: true
        )
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
        screenAcknowledgementOracle = nil
        audioStateText = "Inactive"
        isRemoteAudioAvailable = false
        isRemoteAudioPlaying = false
        audioPlayoutOracle = nil
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
    /// Recovery owns an immutable pre-request regression baseline; its first post-authorization
    /// snapshot establishes the new cumulative-counter floor.
    @discardableResult
    private func beginIOSPlayoutProof(
        requestRecovery: Bool
    ) -> Task<Void, Never>? {
        retireIOSPlayoutRecoveryAttempt()
        audioPlayoutProofTask?.cancel()
        guard let proofPeer = peer else { return nil }

        audioLifecycle.updateRuntimePlayout(isReady: false)
        let attempt = IOSPlayoutProofAttempt(
            sessionGeneration: sessionGeneration,
            expectedPeer: proofPeer,
            stage: requestRecovery ? .awaitingRecoveryBaseline : .awaitingInitialFloor
        )
        iosPlayoutProofAttempt = attempt
        audioPlayoutProofTimeoutTask?.cancel()
        audioPlayoutProofTimeoutTask = Task { [weak self, weak attempt] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, let attempt else { return }
            self.failIOSPlayoutProofTimeout(attempt)
        }

        let proofTask = Task { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            var remainingPolls = 40

            if requestRecovery {
                var capturedRecoveryBaseline = false
                while remainingPolls > 0 {
                    guard iosPlayoutProofAttemptIsOwned(attempt) else { return }
                    if let diagnostics = await ownedIOSPlayoutDiagnostics(
                        for: attempt,
                        from: proofPeer
                    ) {
                        guard iosPlayoutProofAttemptIsOwned(attempt),
                              attempt.stage == .awaitingRecoveryBaseline else { return }
                        attempt.captureRecoveryBaseline(
                            callbackCount: diagnostics.playoutCallbackCount,
                            frameCount: diagnostics.playoutFrameCount,
                            failureCount: diagnostics.playoutFailureCount
                        )
                        capturedRecoveryBaseline = true
                        break
                    }
                    remainingPolls -= 1
                    guard await waitForIOSPlayoutProofPoll(attempt) else { return }
                }

                guard capturedRecoveryBaseline, remainingPolls > 0,
                      iosPlayoutProofAttemptIsOwned(attempt) else {
                    failIOSPlayoutProofTimeout(attempt)
                    return
                }

                let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
                attempt.recoveryAuthorization = authorization
                attempt.stage = .awaitingRecoveryAuthorization
                audioPlayoutRecoveryAuthorization = authorization

                guard iosPlayoutProofAttemptIsOwned(attempt),
                      attempt.recoveryAuthorization === authorization,
                      audioPlayoutRecoveryAuthorization === authorization else {
                    authorization.revoke()
                    return
                }
                await requestIOSPlayoutRecovery(
                    on: proofPeer,
                    authorization: authorization
                )
                guard iosPlayoutProofAttemptIsOwned(attempt),
                      attempt.recoveryAuthorization === authorization,
                      audioPlayoutRecoveryAuthorization === authorization else {
                    authorization.revoke()
                    return
                }
            }

            while remainingPolls > 0 {
                guard iosPlayoutProofAttemptIsOwned(attempt) else { return }
                if attempt.recoveryAuthorization?.isValid == true {
                    #if DEBUG
                    debugIOSPlayoutRecoveryPendingObserver?()
                    #endif
                    remainingPolls -= 1
                    guard await waitForIOSPlayoutProofPoll(attempt) else { return }
                    continue
                }

                if let diagnostics = await ownedIOSPlayoutDiagnostics(
                    for: attempt,
                    from: proofPeer
                ), evaluateIOSPlayoutDiagnostics(diagnostics, for: attempt) {
                    return
                }
                remainingPolls -= 1
                guard await waitForIOSPlayoutProofPoll(attempt) else { return }
            }

            failIOSPlayoutProofTimeout(attempt)
        }
        audioPlayoutProofTask = proofTask
        return proofTask
    }

    private func waitForIOSPlayoutProofPoll(
        _ attempt: IOSPlayoutProofAttempt
    ) async -> Bool {
        guard iosPlayoutProofAttemptIsOwned(attempt) else { return false }
        do {
            try await Task.sleep(for: .milliseconds(50))
        } catch {
            return false
        }
        return iosPlayoutProofAttemptIsOwned(attempt)
    }

    private func refreshIOSPlayoutProof() {
        guard let proofPeer = peer,
              let attempt = iosPlayoutProofAttempt,
              attempt.expectedPeer === proofPeer else { return }
        Task { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            await refreshIOSPlayoutProof(for: attempt, from: proofPeer)
        }
    }

    private func refreshIOSPlayoutProof(
        for attempt: IOSPlayoutProofAttempt,
        from proofPeer: WebRTCPeer
    ) async {
        guard iosPlayoutProofAttemptIsOwned(attempt),
              attempt.stage != .awaitingRecoveryBaseline,
              attempt.recoveryAuthorization?.isValid != true else { return }
        guard let diagnostics = await ownedIOSPlayoutDiagnostics(
            for: attempt,
            from: proofPeer
        ) else { return }
        _ = evaluateIOSPlayoutDiagnostics(diagnostics, for: attempt)
    }

    private func ownedIOSPlayoutDiagnostics(
        for attempt: IOSPlayoutProofAttempt,
        from proofPeer: WebRTCPeer
    ) async -> WebRTCIOSPlayoutDiagnostics? {
        guard !Task.isCancelled,
              iosPlayoutProofAttemptIsOwned(attempt),
              attempt.expectedPeer === proofPeer else { return nil }

        let diagnostics = await readIOSPlayoutDiagnostics(from: proofPeer)
        guard !Task.isCancelled,
              iosPlayoutProofAttemptIsOwned(attempt),
              attempt.expectedPeer === proofPeer else { return nil }
        if let diagnostics {
            publishIOSPlayoutOracle(
                diagnostics,
                from: proofPeer,
                generation: attempt.sessionGeneration
            )
        }
        return diagnostics
    }

    private func readIOSPlayoutDiagnostics(
        from sourcePeer: WebRTCPeer
    ) async -> WebRTCIOSPlayoutDiagnostics? {
        #if DEBUG
        if let debugIOSPlayoutDiagnosticsReader {
            return await debugIOSPlayoutDiagnosticsReader(sourcePeer)
        }
        #endif
        return await sourcePeer.iOSPlayoutDiagnostics()
    }

    private func refreshIOSPlayoutOracle(
        from sourcePeer: WebRTCPeer,
        generation: UUID
    ) async {
        guard generation == sessionGeneration,
              peer === sourcePeer else { return }
        guard let diagnostics = await readIOSPlayoutDiagnostics(from: sourcePeer) else {
            return
        }
        publishIOSPlayoutOracle(
            diagnostics,
            from: sourcePeer,
            generation: generation
        )
    }

    private func publishIOSPlayoutOracle(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        from sourcePeer: WebRTCPeer,
        generation: UUID
    ) {
        guard generation == sessionGeneration,
              peer === sourcePeer else { return }
        audioPlayoutOracle = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: generation,
            diagnostics: diagnostics,
            inboundAudio: statistics?.inboundAudio
        )
    }

    private func requestIOSPlayoutRecovery(
        on proofPeer: WebRTCPeer,
        authorization: WebRTCIOSPlayoutRecoveryAuthorization
    ) async {
        #if DEBUG
        if let debugIOSPlayoutRecoveryRequester {
            await debugIOSPlayoutRecoveryRequester(proofPeer, authorization)
            return
        }
        #endif
        await proofPeer.requestIOSPlayoutRecovery(authorization: authorization)
    }

    private func iosPlayoutProofAttemptIsOwned(
        _ attempt: IOSPlayoutProofAttempt
    ) -> Bool {
        guard iosPlayoutProofAttempt === attempt,
              attempt.sessionGeneration == sessionGeneration else { return false }
        if let expectedPeer = attempt.expectedPeer {
            return peer === expectedPeer
        }
        return true
    }

    #if DEBUG
    private func iosPlayoutProofAttempt(
        matches handle: WorldwideIOSPlayoutProofDebugHandle
    ) -> IOSPlayoutProofAttempt? {
        guard let attempt = iosPlayoutProofAttempt,
              attempt.proofAttemptID == handle.proofAttemptID,
              attempt.counterWindowID == handle.counterWindowID,
              attempt.sessionGeneration == handle.sessionGeneration,
              iosPlayoutProofAttemptIsOwned(attempt) else { return nil }
        return attempt
    }
    #endif

    private func retireIOSPlayoutRecoveryAttempt(
        _ expectedAttempt: IOSPlayoutProofAttempt? = nil
    ) {
        if let expectedAttempt, iosPlayoutProofAttempt !== expectedAttempt { return }
        let attempt = iosPlayoutProofAttempt
        let authorization = attempt?.recoveryAuthorization
            ?? audioPlayoutRecoveryAuthorization
        audioPlayoutProofTimeoutTask?.cancel()
        audioPlayoutProofTimeoutTask = nil
        iosPlayoutProofAttempt = nil
        if audioPlayoutRecoveryAuthorization === authorization {
            audioPlayoutRecoveryAuthorization = nil
        }
        attempt?.recoveryAuthorization = nil
        authorization?.revoke()
    }

    private func failIOSPlayoutProofTimeout(_ attempt: IOSPlayoutProofAttempt) {
        guard iosPlayoutProofAttemptIsOwned(attempt) else { return }
        retireIOSPlayoutRecoveryAttempt(attempt)
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            failureMessage: "The iPhone audio output did not start in full-quality stereo.",
            diagnostic: "RemoteIO produced no verified playout callback within two seconds."
        )
    }

    /// Returns true when this exact proof window reaches a terminal healthy or failed state.
    @discardableResult
    private func evaluateIOSPlayoutDiagnostics(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        for attempt: IOSPlayoutProofAttempt
    ) -> Bool {
        guard iosPlayoutProofAttemptIsOwned(attempt) else { return false }

        if let authorization = attempt.recoveryAuthorization {
            guard audioPlayoutRecoveryAuthorization === authorization else { return false }
            if authorization.isValid { return false }
            if attempt.stage == .awaitingRecoveryAuthorization {
                attempt.stage = .awaitingPostRecoveryFloor
            }
        }

        if let callbackRegressionFloor = attempt.lastCallbackCount
            ?? attempt.recoveryBaseline?.callbackCount,
           diagnostics.playoutCallbackCount < callbackRegressionFloor {
            return failIOSPlayoutProof(
                attempt,
                diagnostics: diagnostics,
                diagnosticOverride: "RemoteIO callback counter regressed from \(callbackRegressionFloor) to \(diagnostics.playoutCallbackCount)."
            )
        }
        if let frameRegressionFloor = attempt.lastFrameCount
            ?? attempt.recoveryBaseline?.frameCount,
           diagnostics.playoutFrameCount < frameRegressionFloor {
            return failIOSPlayoutProof(
                attempt,
                diagnostics: diagnostics,
                diagnosticOverride: "RemoteIO frame counter regressed from \(frameRegressionFloor) to \(diagnostics.playoutFrameCount)."
            )
        }
        if let failureRegressionFloor = attempt.lastFailureCount
            ?? attempt.recoveryBaseline?.failureCount,
           diagnostics.playoutFailureCount < failureRegressionFloor {
            return failIOSPlayoutProof(
                attempt,
                diagnostics: diagnostics,
                diagnosticOverride: "RemoteIO failure counter regressed from \(failureRegressionFloor) to \(diagnostics.playoutFailureCount)."
            )
        }

        guard diagnostics.playoutFailureCount == attempt.permittedFailureFloor else {
            return failIOSPlayoutProof(attempt, diagnostics: diagnostics)
        }
        guard diagnostics.failureCode == 0,
              diagnostics.lastLifecycleStatus == noErr,
              diagnostics.lastPlayoutStatus == noErr,
              diagnostics.unexpectedRecordingRequestCount == 0,
              !diagnostics.inputBusEnabled,
              !diagnostics.recoveryRequired,
              !diagnostics.explicitResumeRequired else {
            return failIOSPlayoutProof(attempt, diagnostics: diagnostics)
        }

        attempt.lastCallbackCount = diagnostics.playoutCallbackCount
        attempt.lastFrameCount = diagnostics.playoutFrameCount
        attempt.lastFailureCount = diagnostics.playoutFailureCount

        if attempt.stage == .awaitingInitialFloor
            || attempt.stage == .awaitingPostRecoveryFloor {
            attempt.callbackFloor = diagnostics.playoutCallbackCount
            attempt.frameFloor = diagnostics.playoutFrameCount
            attempt.stage = .awaitingFreshEvidence
            audioLifecycle.updateRuntimePlayout(isReady: false)
            return false
        }

        guard attempt.stage == .awaitingFreshEvidence,
              let callbackFloor = attempt.callbackFloor,
              let frameFloor = attempt.frameFloor else { return false }

        let fullQualityInvariantsHold =
            WorldwideAudioPlayoutOracleSnapshot.routeInvariantsHold(diagnostics)
        let hasFreshCallbackAndFrames = diagnostics.playoutCallbackCount > callbackFloor
            && diagnostics.playoutFrameCount > frameFloor

        guard fullQualityInvariantsHold, hasFreshCallbackAndFrames else {
            audioLifecycle.updateRuntimePlayout(isReady: false)
            return false
        }

        retireIOSPlayoutRecoveryAttempt(attempt)
        audioLifecycle.updateRuntimePlayout(isReady: true)
        return true
    }

    @discardableResult
    private func failIOSPlayoutProof(
        _ attempt: IOSPlayoutProofAttempt,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        diagnosticOverride: String? = nil
    ) -> Bool {
        guard iosPlayoutProofAttemptIsOwned(attempt) else { return false }
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
        let diagnostic = diagnosticOverride
            ?? diagnostics.failureMessage
            ?? "RemoteIO failure=\(diagnostics.failureCode), status=\(diagnostics.lastLifecycleStatus), renderStatus=\(diagnostics.lastPlayoutStatus), callbacks=\(diagnostics.playoutCallbackCount), failures=\(diagnostics.playoutFailureCount), recordRequests=\(diagnostics.unexpectedRecordingRequestCount)."
        retireIOSPlayoutRecoveryAttempt(attempt)
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            failureMessage: message,
            diagnostic: diagnostic
        )
        return true
    }

    private func handleControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        sourcePeer: WebRTCPeer?,
        sourceGeneration: UUID
    ) async {
        let key = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: sourceGeneration,
            requestID: acknowledgement.id
        )
        guard sourceGeneration == sessionGeneration,
              screenAcknowledgementPeerMatchesCurrent(sourcePeer) else {
            inputAuthorization?.revoke()
            return
        }
        if retiredScreenVisibilityRequestKeys.contains(key) {
            inputAuthorization?.revoke()
            return
        }
        if pendingRecoveryProbe?.requestKey == key {
            await completeRecoveryProbe(
                with: acknowledgement,
                inputAuthorization: inputAuthorization,
                sourcePeer: sourcePeer,
                sourceGeneration: sourceGeneration
            )
            return
        }

        guard let pending = pendingScreenVisibilityRequest else {
            cacheEarlyControlAcknowledgement(
                acknowledgement,
                key: key,
                inputAuthorization: inputAuthorization,
                sourcePeer: sourcePeer
            )
            return
        }
        guard pending.key == key,
              pendingScreenVisibilityRequestIsOwned(pending),
              screenAcknowledgementPeer(sourcePeer, matches: pending.expectedPeer) else {
            cacheEarlyControlAcknowledgement(
                acknowledgement,
                key: key,
                inputAuthorization: inputAuthorization,
                sourcePeer: sourcePeer
            )
            return
        }

        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        pendingScreenVisibilityRequest = nil
        let reachedTarget = applyControlAcknowledgement(
            acknowledgement,
            inputAuthorization: inputAuthorization,
            pending: pending
        )
        retireScreenVisibilityRequestKey(key)
        pending.continuation.resume(returning: reachedTarget)
    }

    private func screenAcknowledgementPeerMatchesCurrent(_ sourcePeer: WebRTCPeer?) -> Bool {
        if let sourcePeer {
            return peer === sourcePeer
        }
        #if DEBUG
        return peer == nil
            && (debugScreenVisibilityRequestSender != nil
                || debugScreenVisibilityRequestSenderV2 != nil)
        #else
        return false
        #endif
    }

    private func screenAcknowledgementPeer(
        _ sourcePeer: WebRTCPeer?,
        matches expectedPeer: WebRTCPeer?
    ) -> Bool {
        if let expectedPeer {
            return sourcePeer === expectedPeer
        }
        return sourcePeer == nil
    }

    private func pendingScreenVisibilityRequestIsOwned(
        _ pending: PendingScreenVisibilityRequest
    ) -> Bool {
        guard pending.sessionGeneration == sessionGeneration,
              pending.queueGeneration == screenVisibilityQueueGeneration else {
            return false
        }
        if pending.isVisible {
            return currentScreenPresentationLease == pending.lease
                && screenShowOperationByLeaseID[pending.lease.id] == pending.operationID
        }
        return screenTeardownOperationByLeaseID[pending.lease.id] == pending.operationID
    }

    private func cacheEarlyControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        key: WorldwideScreenVisibilityRequestKey,
        inputAuthorization: WebRTCInputAuthorization?,
        sourcePeer: WebRTCPeer?
    ) {
        guard !retiredScreenVisibilityRequestKeys.contains(key) else {
            inputAuthorization?.revoke()
            return
        }
        let retainedInputAuthorization: WebRTCInputAuthorization?
        if acknowledgement.state == .active,
           let currentLease = currentScreenPresentationLease,
           screenShowOperationByLeaseID[currentLease.id] != nil,
           remoteScreenOwnerLease == currentLease {
            retainedInputAuthorization = inputAuthorization
        } else {
            inputAuthorization?.revoke()
            retainedInputAuthorization = nil
        }
        if let replaced = earlyControlAcknowledgements.updateValue(
            ReceivedControlAcknowledgement(
                acknowledgement: acknowledgement,
                inputAuthorization: retainedInputAuthorization,
                sourcePeer: sourcePeer
            ),
            forKey: key
        ) {
            replaced.inputAuthorization?.revoke()
        }
        if earlyControlAcknowledgements.count > 8,
           let oldest = earlyControlAcknowledgements.keys.first {
            earlyControlAcknowledgements.removeValue(forKey: oldest)?
                .inputAuthorization?.revoke()
        }
    }

    @discardableResult
    private func applyControlAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        pending: PendingScreenVisibilityRequest
    ) -> Bool {
        screenAcknowledgementOracle = WorldwideScreenAcknowledgementOracleSnapshot(
            sessionGeneration: pending.key.sessionGeneration,
            requestID: pending.key.requestID,
            command: pending.isVisible ? .show : .hide,
            state: acknowledgement.state == .active ? .active : .inactive
        )
        if pending.isVisible {
            guard acknowledgement.state == .active,
                  currentScreenPresentationLease == pending.lease,
                  pendingScreenVisibilityRequestIsOwned(pending),
                  canViewScreen else {
                inputAuthorization?.revoke()
                acceptsActiveScreenAcknowledgement = false
                if acknowledgement.state == .inactive,
                   remoteScreenOwnerLease == pending.lease {
                    remoteScreenOwnerLease = nil
                }
                if activeScreenPresentationLease == pending.lease {
                    activeScreenPresentationLease = nil
                }
                isScreenVisible = false
                remoteHideRequired = remoteScreenOwnerLease != nil
                invalidateRemoteInputState()
                if isPeerConnected {
                    stateText = "Connected"
                }
                lastError = "The Mac could not start screen capture. Check Screen Recording permission."
                return false
            }

            let capability = acknowledgement.inputCapability.flatMap { capability in
                capability.screenRequestID == pending.key.requestID ? capability : nil
            }
            if acknowledgement.inputCapability != nil, capability == nil {
                inputAuthorization?.revoke()
            }
            activeScreenPresentationLease = pending.lease
            remoteScreenOwnerLease = pending.lease
            isScreenVisible = true
            acceptsActiveScreenAcknowledgement = false
            remoteHideRequired = true
            installRemoteInputCapability(
                capability,
                authorization: capability == nil ? nil : inputAuthorization
            )
            #if DEBUG
            debugActiveScreenPresentationLease = pending.lease
            #endif
            stateText = "Screen live"
            return true
        }

        inputAuthorization?.revoke()
        acceptsActiveScreenAcknowledgement = false
        guard acknowledgement.state == .inactive else {
            remoteScreenOwnerLease = pending.lease
            remoteHideRequired = true
            if currentScreenPresentationLease == pending.lease {
                isScreenVisible = false
                invalidateRemoteInputState()
            }
            return false
        }

        if remoteScreenOwnerLease == pending.lease {
            remoteScreenOwnerLease = nil
        }
        if activeScreenPresentationLease == pending.lease {
            activeScreenPresentationLease = nil
        }
        #if DEBUG
        if debugActiveScreenPresentationLease == pending.lease {
            debugActiveScreenPresentationLease = nil
        }
        #endif
        if currentScreenPresentationLease == pending.lease {
            isScreenVisible = false
            invalidateRemoteInputState()
        }
        remoteHideRequired = remoteScreenOwnerLease != nil
        if isPeerConnected {
            stateText = "Connected"
        }
        return true
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
            requestKey: nil,
            expectedPeer: peer
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
                requestKey: WorldwideScreenVisibilityRequestKey(
                    sessionGeneration: generation,
                    requestID: requestID
                ),
                expectedPeer: peer
            )
            let key = WorldwideScreenVisibilityRequestKey(
                sessionGeneration: generation,
                requestID: requestID
            )
            if let received = earlyControlAcknowledgements.removeValue(forKey: key) {
                await completeRecoveryProbe(
                    with: received.acknowledgement,
                    inputAuthorization: received.inputAuthorization,
                    sourcePeer: received.sourcePeer,
                    sourceGeneration: generation
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
        inputAuthorization: WebRTCInputAuthorization?,
        sourcePeer: WebRTCPeer?,
        sourceGeneration: UUID
    ) async {
        // A recovery proof is always Hide/Inactive and therefore must never retain input.
        inputAuthorization?.revoke()
        guard let probe = pendingRecoveryProbe,
              let requestKey = probe.requestKey,
              probe.sessionGeneration == sessionGeneration,
              sourceGeneration == sessionGeneration,
              probe.epoch == recoveryProofEpoch,
              requestKey.requestID == acknowledgement.id,
              requestKey.sessionGeneration == sourceGeneration,
              screenAcknowledgementPeer(sourcePeer, matches: probe.expectedPeer),
              acknowledgement.state == .inactive,
              recoveryProofRequired else {
            return
        }

        retireScreenVisibilityRequestKey(requestKey)
        pendingRecoveryProbe = nil
        restartAnswerAwaitingSendEpoch = nil
        recoveryProofRequired = false
        iceIsConnected = true
        isPeerConnected = true
        isControlChannelReady = true
        isConnecting = false
        resetScreenPresentationState(rotateQueueGeneration: true)
        stateText = "Connected"
        // The authenticated, current-generation inactive acknowledgement is the recovery proof
        // that permits remote audio to leave the fail-closed mute gate.
        audioLifecycle.transportBecameHealthy()
        await recoveryCoordinator?.iceStateChanged(.connected)
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
    func debugInstallStatisticsStarter(
        _ starter: @escaping @MainActor (WebRTCPeer) async throws -> Void
    ) {
        debugStatisticsStarter = starter
    }

    /// Keeps production `connect` ownership active without opening a real WebSocket, allowing
    /// reentrancy tests to prove whether a replacement connect is accepted deterministically.
    func debugInstallSessionRunner(_ runner: @escaping @MainActor () async -> Void) {
        debugSessionRunner = runner
    }

    func debugInstallIOSPlayoutDiagnosticsReader(
        _ reader: @escaping @MainActor (WebRTCPeer) async -> WebRTCIOSPlayoutDiagnostics?
    ) {
        debugIOSPlayoutDiagnosticsReader = reader
    }

    func debugInstallIOSPlayoutRecoveryRequester(
        _ requester: @escaping @MainActor (
            WebRTCPeer,
            WebRTCIOSPlayoutRecoveryAuthorization
        ) async -> Void
    ) {
        debugIOSPlayoutRecoveryRequester = requester
    }

    func debugInstallIOSPlayoutRecoveryPendingObserver(
        _ observer: @escaping @MainActor () -> Void
    ) {
        debugIOSPlayoutRecoveryPendingObserver = observer
    }

    func debugInstallIOSPlayoutPeerForRaceTests(_ newPeer: WebRTCPeer) {
        precondition(peer == nil)
        sessionGeneration = UUID()
        peer = newPeer
    }

    func debugBeginIOSPlayoutProofForRaceTests(
        requestRecovery: Bool
    ) -> Task<Void, Never>? {
        beginIOSPlayoutProof(requestRecovery: requestRecovery)
    }

    func debugRefreshIOSPlayoutProofForRaceTests() async {
        guard let proofPeer = peer,
              let attempt = iosPlayoutProofAttempt else { return }
        await refreshIOSPlayoutProof(for: attempt, from: proofPeer)
    }

    func debugRefreshIOSPlayoutOracleForTests(from sourcePeer: WebRTCPeer) async {
        await refreshIOSPlayoutOracle(
            from: sourcePeer,
            generation: sessionGeneration
        )
    }

    var debugIOSPlayoutRecoveryIsAuthorized: Bool {
        audioPlayoutRecoveryAuthorization?.isValid == true
    }

    var debugIOSPlayoutRecoveryAuthorizationForTests:
        WebRTCIOSPlayoutRecoveryAuthorization? {
        audioPlayoutRecoveryAuthorization
    }

    func debugStartIOSPlayoutProofAttemptForTests(
        requestRecovery: Bool,
        preRecoveryDiagnostics: WebRTCIOSPlayoutDiagnostics? = nil,
        expectedPeer: WebRTCPeer? = nil
    ) -> WorldwideIOSPlayoutProofDebugHandle {
        if let expectedPeer {
            precondition(peer === expectedPeer)
        }
        retireIOSPlayoutRecoveryAttempt()
        audioPlayoutProofTask?.cancel()
        audioLifecycle.updateRuntimePlayout(isReady: false)

        let authorization = requestRecovery
            ? WebRTCIOSPlayoutRecoveryAuthorization()
            : nil
        let attempt = IOSPlayoutProofAttempt(
            sessionGeneration: sessionGeneration,
            expectedPeer: expectedPeer,
            stage: requestRecovery
                ? .awaitingRecoveryBaseline
                : .awaitingInitialFloor
        )
        if requestRecovery {
            attempt.captureRecoveryBaseline(
                callbackCount: preRecoveryDiagnostics?.playoutCallbackCount ?? 0,
                frameCount: preRecoveryDiagnostics?.playoutFrameCount ?? 0,
                failureCount: preRecoveryDiagnostics?.playoutFailureCount ?? 0
            )
            attempt.recoveryAuthorization = authorization
            attempt.stage = .awaitingRecoveryAuthorization
        } else if let preRecoveryDiagnostics {
            attempt.lastCallbackCount = preRecoveryDiagnostics.playoutCallbackCount
            attempt.lastFrameCount = preRecoveryDiagnostics.playoutFrameCount
            attempt.lastFailureCount = preRecoveryDiagnostics.playoutFailureCount
        }
        iosPlayoutProofAttempt = attempt
        audioPlayoutRecoveryAuthorization = authorization
        return WorldwideIOSPlayoutProofDebugHandle(
            proofAttemptID: attempt.proofAttemptID,
            counterWindowID: attempt.counterWindowID,
            sessionGeneration: attempt.sessionGeneration
        )
    }

    @discardableResult
    func debugEvaluateIOSPlayoutDiagnosticsForTests(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        handle: WorldwideIOSPlayoutProofDebugHandle,
        source: WorldwideIOSPlayoutProofDebugSource
    ) -> Bool {
        _ = source
        guard let attempt = iosPlayoutProofAttempt(matches: handle) else { return false }
        return evaluateIOSPlayoutDiagnostics(diagnostics, for: attempt)
    }

    func debugTimeoutIOSPlayoutProofForTests(
        handle: WorldwideIOSPlayoutProofDebugHandle
    ) {
        guard let attempt = iosPlayoutProofAttempt(matches: handle) else { return }
        failIOSPlayoutProofTimeout(attempt)
    }

    var debugIOSPlayoutProofState: WorldwideIOSPlayoutProofDebugState {
        let attempt = iosPlayoutProofAttempt
        let handle = attempt.map { attempt in
            WorldwideIOSPlayoutProofDebugHandle(
                proofAttemptID: attempt.proofAttemptID,
                counterWindowID: attempt.counterWindowID,
                sessionGeneration: attempt.sessionGeneration
            )
        }
        let debugStage: WorldwideIOSPlayoutProofDebugStage?
        switch attempt?.stage {
        case .awaitingRecoveryBaseline, .awaitingInitialFloor:
            debugStage = .awaitingInitialFloor
        case .awaitingRecoveryAuthorization:
            debugStage = .awaitingRecoveryAuthorization
        case .awaitingPostRecoveryFloor:
            debugStage = .awaitingPostRecoveryFloor
        case .awaitingFreshEvidence:
            debugStage = .awaitingFreshEvidence
        case nil:
            debugStage = nil
        }
        let authorization = attempt?.recoveryAuthorization
        return WorldwideIOSPlayoutProofDebugState(
            handle: handle,
            stage: debugStage,
            callbackFloor: attempt?.callbackFloor,
            frameFloor: attempt?.frameFloor,
            permittedFailureFloor: attempt?.permittedFailureFloor,
            lastCallbackCount: attempt?.lastCallbackCount,
            lastFrameCount: attempt?.lastFrameCount,
            lastFailureCount: attempt?.lastFailureCount,
            recoveryAuthorizationIdentity: authorization.map(ObjectIdentifier.init),
            recoveryAuthorizationIsValid: authorization?.isValid == true
        )
    }

    func debugDeliverReadyForRaceTests() async throws {
        guard let signaling else { throw CancellationError() }
        let generation = sessionGeneration
        try await handleSignalingEvent(
            .ready(
                role: .host,
                invitationExpiresAt: Date().addingTimeInterval(60),
                iceServers: []
            ),
            client: signaling,
            generation: generation
        )
    }

    func debugSignalingIs(_ client: RendezvousSignalingClient) -> Bool {
        signaling === client
    }

    func debugInstallRemoteInputSender(
        _ sender: @escaping @MainActor (
            WebRTCPeer,
            WebRTCInputAction,
            WebRTCInputCapability,
            WebRTCInputAuthorization
        ) async throws -> UInt64
    ) {
        debugRemoteInputSender = sender
    }

    /// Installs a complete, synthetic input generation without starting its drain. Tests can
    /// then suspend the old generation inside the injectable send and replace it atomically.
    @discardableResult
    func debugInstallQueuedRemoteInputSessionForRaceTests(
        peer newPeer: WebRTCPeer,
        focusGeneration: UInt64,
        diagnostic: String
    ) -> WebRTCInputAuthorization {
        invalidateRemoteInputState()
        sessionGeneration = UUID()
        peer = newPeer
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: focusGeneration,
            supportsPrimaryDrag: true
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
        let lease = WorldwideScreenPresentationLease(sessionGeneration: sessionGeneration)
        currentScreenPresentationLease = lease
        activeScreenPresentationLease = lease
        remoteScreenOwnerLease = lease
        remoteHideRequired = true
        #if DEBUG
        debugCurrentScreenPresentationLease = lease
        debugActiveScreenPresentationLease = lease
        #endif
        lastDiagnostic = diagnostic
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

    func debugDrainRemoteInputQueueForRaceTests() async {
        await drainRemoteInputQueue(inputGeneration: remoteInputGeneration)
    }

    /// Routes tests through the production terminal-session path without requiring live media.
    func debugFailSessionForTests(_ message: String) {
        failSession(message, generation: sessionGeneration)
    }

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
        let lease = currentScreenPresentationLease
            ?? WorldwideScreenPresentationLease(sessionGeneration: sessionGeneration)
        currentScreenPresentationLease = lease
        activeScreenPresentationLease = lease
        remoteScreenOwnerLease = lease
        debugCurrentScreenPresentationLease = lease
        debugActiveScreenPresentationLease = lease
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
            capability: remoteInputCapability,
            authorizationIdentity: remoteInputAuthorization.map(ObjectIdentifier.init),
            capabilityInstalled: remoteInputCapability != nil,
            authorizationInstalled: remoteInputAuthorization != nil,
            focusGeneration: focusedInputGeneration,
            queuedActionCount: remoteInputQueue.count,
            pendingActionCount: pendingRemoteInputs.count,
            inputGeneration: remoteInputGeneration,
            inputAvailable: isRemoteInputAvailable,
            acceptsActiveScreenAcknowledgement: acceptsActiveScreenAcknowledgement,
            remoteHideRequired: remoteHideRequired,
            hideRequestWouldBeNoOp: currentScreenPresentationLease.map {
                !screenPresentationNeedsRemoteHide($0)
            } ?? !remoteHideRequired,
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
            inputAuthorization: authorization,
            sourcePeer: peer,
            sourceGeneration: sessionGeneration
        )
        return authorization
    }

    func debugSimulateLocallyHiddenPendingShow() {
        isScreenVisible = false
    }

    func debugInstallScreenSessionForTests(
        peer newPeer: WebRTCPeer,
        generation: UUID = UUID(),
        visible: Bool = false
    ) {
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            clearRequestHistory: true
        )
        peer = newPeer
        sessionGeneration = generation
        isPeerConnected = true
        iceIsConnected = true
        isControlChannelReady = true
        isScreenVisible = visible
        acceptsActiveScreenAcknowledgement = visible
        remoteHideRequired = visible
    }

    @discardableResult
    func debugInstallActiveScreenPresentationForTests(
        peer newPeer: WebRTCPeer,
        generation: UUID = UUID(),
        leaseID: UUID = UUID(),
        screenRequestID: UInt64 = 1
    ) -> WorldwideScreenPresentationDebugFixture {
        debugInstallScreenSessionForTests(
            peer: newPeer,
            generation: generation,
            visible: true
        )
        let lease = WorldwideScreenPresentationLease(
            id: leaseID,
            sessionGeneration: generation
        )
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: screenRequestID,
            supportsPrimaryDrag: true
        )
        let authorization = WebRTCInputAuthorization()
        remoteInputCapability = capability
        remoteInputAuthorization = authorization
        focusedInputGeneration = screenRequestID
        focusedInputIsSecure = false
        currentScreenPresentationLease = lease
        activeScreenPresentationLease = lease
        remoteScreenOwnerLease = lease
        remoteHideRequired = true
        debugCurrentScreenPresentationLease = lease
        debugActiveScreenPresentationLease = lease
        return WorldwideScreenPresentationDebugFixture(
            lease: lease,
            authorization: authorization
        )
    }

    func debugScreenPeerIs(_ expectedPeer: WebRTCPeer) -> Bool {
        peer === expectedPeer
    }

    var debugScreenPresentationState: WorldwideScreenPresentationDebugState {
        WorldwideScreenPresentationDebugState(
            sessionGeneration: sessionGeneration,
            currentLease: currentScreenPresentationLease,
            activeLease: activeScreenPresentationLease,
            isScreenVisible: isScreenVisible,
            inputAvailable: isRemoteInputAvailable,
            remoteHideRequired: remoteHideRequired,
            pendingRequestKey: pendingScreenVisibilityRequest?.key,
            displacedPendingRequestCount:
                debugDisplacedPendingScreenVisibilityRequests.count,
            hasActiveSession: hasActiveSession
        )
    }

    func debugInstallScreenVisibilityRequestSender(
        _ sender: @escaping @MainActor (Bool) async throws -> UInt64
    ) {
        debugScreenVisibilityRequestSender = sender
    }

    func debugInstallScreenVisibilityRequestSender(
        _ sender: @escaping @MainActor (
            WorldwideScreenVisibilityDebugRequest
        ) async throws -> UInt64
    ) {
        debugScreenVisibilityRequestSenderV2 = sender
    }

    func debugInstallScreenVisibilityPostSendHook(
        _ hook: @escaping @MainActor (
            WorldwideScreenVisibilityPostSendDebugEvent
        ) async -> Void
    ) {
        debugScreenVisibilityPostSendHook = hook
    }

    func debugWaitForScreenVisibilityPostSendProcessing(
        operationID: UUID
    ) async {
        if debugProcessedScreenVisibilityPostSendOperationIDs.remove(operationID) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            debugScreenVisibilityPostSendProcessingWaiters[
                operationID,
                default: []
            ].append(continuation)
        }
    }

    @discardableResult
    func debugDeliverControlAcknowledgement(
        key: WorldwideScreenVisibilityRequestKey,
        state: WebRTCScreenState,
        inputCapability: WebRTCInputCapability? = nil,
        sourcePeer: WebRTCPeer? = nil
    ) async -> WebRTCInputAuthorization? {
        let authorization = inputCapability.map { _ in WebRTCInputAuthorization() }
        await handleControlAcknowledgement(
            WebRTCControlAcknowledgement(
                id: key.requestID,
                state: state,
                inputCapability: inputCapability
            ),
            inputAuthorization: authorization,
            sourcePeer: sourcePeer ?? peer,
            sourceGeneration: key.sessionGeneration
        )
        return authorization
    }

    func debugWaitForPendingScreenVisibilityRequest(
        _ key: WorldwideScreenVisibilityRequestKey
    ) async {
        if debugScreenPresentationState.pendingRequestKey == key {
            return
        }
        await withCheckedContinuation { continuation in
            debugPendingScreenVisibilityWaiters[key, default: []].append(continuation)
        }
    }

    private func notifyDebugPendingScreenVisibilityWaiters(
        _ key: WorldwideScreenVisibilityRequestKey
    ) {
        let waiters = debugPendingScreenVisibilityWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func notifyDebugScreenVisibilityPostSendProcessed(_ operationID: UUID) {
        guard debugScreenVisibilityPostSendHook != nil
            || debugScreenVisibilityPostSendProcessingWaiters[operationID] != nil else {
            return
        }
        let waiters = debugScreenVisibilityPostSendProcessingWaiters.removeValue(
            forKey: operationID
        ) ?? []
        guard !waiters.isEmpty else {
            debugProcessedScreenVisibilityPostSendOperationIDs.insert(operationID)
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func debugTriggerScreenVisibilityTimeout(
        key: WorldwideScreenVisibilityRequestKey
    ) {
        guard let pending = pendingScreenVisibilityRequest else { return }
        controlAcknowledgementTimedOut(
            key: key,
            lease: pending.lease,
            operationID: pending.operationID,
            expectedPeer: pending.expectedPeer,
            queueGeneration: pending.queueGeneration
        )
    }

    func debugDeliverControlAcknowledgement(
        id: UInt64,
        state: WebRTCScreenState
    ) async {
        await handleControlAcknowledgement(
            WebRTCControlAcknowledgement(id: id, state: state),
            inputAuthorization: nil,
            sourcePeer: peer,
            sourceGeneration: sessionGeneration
        )
    }
    #endif

    private func clearEarlyControlAcknowledgements() {
        for received in earlyControlAcknowledgements.values {
            received.inputAuthorization?.revoke()
        }
        earlyControlAcknowledgements.removeAll(keepingCapacity: false)
    }

    private func retireScreenVisibilityRequestKey(
        _ key: WorldwideScreenVisibilityRequestKey
    ) {
        earlyControlAcknowledgements.removeValue(forKey: key)?
            .inputAuthorization?.revoke()
        guard retiredScreenVisibilityRequestKeys.insert(key).inserted else { return }
        retiredScreenVisibilityRequestOrder.append(key)
        if retiredScreenVisibilityRequestOrder.count > 256 {
            let retired = retiredScreenVisibilityRequestOrder.removeFirst()
            retiredScreenVisibilityRequestKeys.remove(retired)
        }
    }

    #if DEBUG
    private func installPendingScreenVisibilityRequest(
        _ pending: PendingScreenVisibilityRequest
    ) {
        if let displaced = pendingScreenVisibilityRequest {
            debugDisplacedPendingScreenVisibilityRequests.append(displaced)
        }
        pendingScreenVisibilityRequest = pending
    }
    #endif

    private func completePendingScreenVisibilityRequest(success: Bool) {
        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        guard let pending = pendingScreenVisibilityRequest else { return }
        pendingScreenVisibilityRequest = nil
        retireScreenVisibilityRequestKey(pending.key)
        pending.continuation.resume(returning: success)
    }

    private func controlAcknowledgementTimedOut(
        key: WorldwideScreenVisibilityRequestKey,
        lease: WorldwideScreenPresentationLease,
        operationID: UUID,
        expectedPeer: WebRTCPeer?,
        queueGeneration: UUID
    ) {
        guard let pending = pendingScreenVisibilityRequest,
              pending.key == key,
              pending.lease == lease,
              pending.operationID == operationID,
              pending.queueGeneration == queueGeneration,
              screenAcknowledgementPeer(expectedPeer, matches: pending.expectedPeer),
              pendingScreenVisibilityRequestIsOwned(pending) else {
            return
        }
        completePendingScreenVisibilityRequest(success: false)
    }

    private func resetScreenPresentationState(
        rotateQueueGeneration: Bool,
        clearRequestHistory: Bool = false
    ) {
        controlAcknowledgementTimeoutTask?.cancel()
        controlAcknowledgementTimeoutTask = nil
        completePendingScreenVisibilityRequest(success: false)
        #if DEBUG
        let displacedPendingRequests = debugDisplacedPendingScreenVisibilityRequests
        debugDisplacedPendingScreenVisibilityRequests.removeAll(keepingCapacity: false)
        for pending in displacedPendingRequests {
            pending.continuation.resume(returning: false)
        }
        let postSendProcessingWaiters = debugScreenVisibilityPostSendProcessingWaiters.values
            .flatMap { $0 }
        debugScreenVisibilityPostSendProcessingWaiters.removeAll(keepingCapacity: false)
        debugProcessedScreenVisibilityPostSendOperationIDs.removeAll(keepingCapacity: false)
        for waiter in postSendProcessingWaiters {
            waiter.resume()
        }
        #endif

        let queued = screenVisibilityQueue
        screenVisibilityQueue.removeAll(keepingCapacity: false)
        screenVisibilityDrainTask?.cancel()
        screenVisibilityDrainTask = nil
        if rotateQueueGeneration {
            screenVisibilityQueueGeneration = UUID()
        }
        for operation in queued {
            operation.completion?(false)
        }

        screenTeardownOperationByLeaseID.removeAll(keepingCapacity: false)
        screenShowOperationByLeaseID.removeAll(keepingCapacity: false)
        currentScreenPresentationLease = nil
        activeScreenPresentationLease = nil
        remoteScreenOwnerLease = nil
        acceptsActiveScreenAcknowledgement = false
        remoteHideRequired = false
        screenVisibilityOperationGeneration = UUID()
        isScreenVisible = false
        invalidateRemoteInputState()
        #if DEBUG
        debugCurrentScreenPresentationLease = nil
        debugActiveScreenPresentationLease = nil
        #endif
        clearEarlyControlAcknowledgements()
        if clearRequestHistory {
            retiredScreenVisibilityRequestKeys.removeAll(keepingCapacity: false)
            retiredScreenVisibilityRequestOrder.removeAll(keepingCapacity: false)
        }
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
        let answerWasAwaitingSend = restartAnswerAwaitingSendEpoch != nil
        if let requestKey = pendingRecoveryProbe?.requestKey {
            earlyControlAcknowledgements.removeValue(forKey: requestKey)?
                .inputAuthorization?.revoke()
            retireScreenVisibilityRequestKey(requestKey)
        }
        recoveryProofEpoch &+= 1
        recoveryProofRequired = recoveryProofRequired || requiresProof
        pendingRecoveryProbe = nil
        restartAnswerAwaitingSendEpoch = answerWasAwaitingSend
            ? recoveryProofEpoch
            : nil
        resetScreenPresentationState(rotateQueueGeneration: true)
        iceIsConnected = false
        stateText = state
    }

    private func hideScreenForPassiveLifecycleIfNeeded() {
        guard let lease = currentScreenPresentationLease else {
            suspendRemoteInputPresentation()
            return
        }
        guard screenPresentationNeedsRemoteHide(lease) else {
            revokeScreenPresentationLocally(for: lease, clearActiveOwnership: false)
            return
        }
        _ = beginPassiveScreenTeardown(for: lease)
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
    let key: WorldwideScreenVisibilityRequestKey
    let isVisible: Bool
    let lease: WorldwideScreenPresentationLease
    let operationID: UUID
    let sessionGeneration: UUID
    let queueGeneration: UUID
    let expectedPeer: WebRTCPeer?
    let continuation: CheckedContinuation<Bool, Never>
}

private struct QueuedScreenVisibilityOperation {
    let lease: WorldwideScreenPresentationLease
    let operationID: UUID
    let isVisible: Bool
    let sessionGeneration: UUID
    let queueGeneration: UUID
    let expectedPeer: WebRTCPeer?
    let completion: (@MainActor (Bool) -> Void)?
}

#if DEBUG
struct WorldwideRemoteInputDebugState: Equatable {
    let capability: WebRTCInputCapability?
    let authorizationIdentity: ObjectIdentifier?
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
    let sourcePeer: WebRTCPeer?
}

private struct PendingRecoveryProbe {
    let sessionGeneration: UUID
    let epoch: UInt64
    let requestKey: WorldwideScreenVisibilityRequestKey?
    let expectedPeer: WebRTCPeer
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
            "The Mac disconnected. Reconnect to the saved paired Mac when it is available."
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
