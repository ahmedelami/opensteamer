import AudioToolbox
import AVFoundation
import CoreGraphics
import Foundation
import RemoteSessionCore
import WebRTCTransport

/// Capability-like token that binds one screen presentation to one media-session generation.
/// Views must present this exact lease on show, input, and teardown calls; a raw request ID is not
/// sufficient because IDs may be reused by a replacement peer.
struct WorldwideScreenPresentationLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UUID

    init(id: UUID = UUID(), sessionGeneration: UUID) {
        self.id = id
        self.sessionGeneration = sessionGeneration
    }
}

/// Composite identity for an in-flight show/hide request across reconnect generations.
struct WorldwideScreenVisibilityRequestKey: Hashable, Sendable {
    let sessionGeneration: UUID
    let requestID: UInt64
}

#if DEBUG
// Debug projections intentionally contain only synthetic ownership state and monotonic counters.
// They expose race-test seams without weakening the production generation/authorization checks.
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

struct WorldwideMacHostedCallCapabilityRetryDebugContext {
    let peer: WebRTCPeer
    let sessionGeneration: UUID
    let negotiationGeneration: UUID
}

struct WorldwideIOSPlayoutProofDebugHandle: Equatable, Sendable {
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
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

/// Ordered phases of one output-only RemoteIO recovery proof window.
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

/// Mutable, attempt-scoped audio proof state confined to `WorldwideSessionViewModel`'s MainActor.
/// UUID ownership and counter floors prevent delayed polling/statistics tasks from certifying a
/// replacement peer or carrying pre-recovery callback progress into a new proof window.
private final class IOSPlayoutProofAttempt {
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
    let expectedPeer: WebRTCPeer?
    let postCallRecoveryMilestone:
        WorldwidePostCallMicrophoneRecoveryMilestone?
    let categoryProofClaim: WorldwideAudioCategoryProofClaim?
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
        audioPolicyGeneration: UUID,
        expectedPeer: WebRTCPeer?,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone? = nil,
        categoryProofClaim: WorldwideAudioCategoryProofClaim? = nil,
        stage: IOSPlayoutProofStage
    ) {
        self.proofAttemptID = proofAttemptID
        self.counterWindowID = counterWindowID
        self.sessionGeneration = sessionGeneration
        self.audioPolicyGeneration = audioPolicyGeneration
        self.expectedPeer = expectedPeer
        self.postCallRecoveryMilestone =
            postCallRecoveryMilestone
        self.categoryProofClaim = categoryProofClaim
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

private enum IOSHostedCallPlayoutProofStage: Equatable {
    case awaitingNativeQuiescence
    case awaitingNativeRecovery
    case awaitingEvidenceFloor
    case awaitingFreshEvidence
    case ready
}

private enum IOSHostedCallPlayoutTimeoutPhase: Equatable {
    case setup
    case evidence
    case steady
}

private enum IOSHostedCallPlayoutProofSource: Equatable {
    case polling
    case statistics
}

private struct IOSHostedCallPlayoutNativeCounterFloor {
    let failureCount: UInt64
    let unexpectedRecordingRequestCount: UInt64
}

private struct IOSHostedCallPlayoutEvidenceFloor {
    let callbackCount: UInt64
    let frameCount: UInt64
    let pcmNonzeroSampleCount: UInt64
    let pcmAbsoluteSampleSum: UInt64
    let failureCount: UInt64
    let unexpectedRecordingRequestCount: UInt64
    let inboundAudio: WebRTCAudioStatistics
    let statisticsCollectedAt: Date
}

private final class IOSPendingStartupConnectedCallPlayout {
    let scopeID: UUID
    let policyID: UUID
    let authorization: WebRTCIOSHostedCallPlayoutAuthorization
    let authorizationIdentity: ObjectIdentifier
    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
    private(set) var expectedPeer: WebRTCPeer?
    private(set) var expectedPeerIdentity: ObjectIdentifier?

    init(
        scopeID: UUID,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization,
        sessionGeneration: UUID,
        audioPolicyGeneration: UUID
    ) {
        self.scopeID = scopeID
        policyID = authorization.policyID
        self.authorization = authorization
        authorizationIdentity = ObjectIdentifier(authorization)
        self.sessionGeneration = sessionGeneration
        self.audioPolicyGeneration = audioPolicyGeneration
    }

    @discardableResult
    func bindFirstPeer(_ peer: WebRTCPeer) -> Bool {
        if let expectedPeer {
            return expectedPeer === peer
        }
        expectedPeer = peer
        expectedPeerIdentity = ObjectIdentifier(peer)
        return true
    }
}

private final class IOSHostedCallPlayoutProofAttempt {
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let scopeID: UUID
    let policyID: UUID
    let origin: WebRTCIOSHostedCallPlayoutOrigin
    let authorization: WebRTCIOSHostedCallPlayoutAuthorization
    let authorizationIdentity: ObjectIdentifier
    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
    let expectedPeer: WebRTCPeer
    let expectedPeerIdentity: ObjectIdentifier
    var stage: IOSHostedCallPlayoutProofStage
    var nativeCounterFloor: IOSHostedCallPlayoutNativeCounterFloor?
    var evidenceFloor: IOSHostedCallPlayoutEvidenceFloor?
    var steadyFloor: IOSHostedCallPlayoutEvidenceFloor?
    var runtimeGateAdmittedAt: Date?
    var timeoutPhase: IOSHostedCallPlayoutTimeoutPhase?
    var timeoutID: UUID?
    var pollOrdinal = 0
    var recoveryRequestCount = 0
    var nextRecoveryRequestPollOrdinal = 0
    var nextDiagnosticReadOrdinal: UInt64 = 1
    var latestAcceptedDiagnosticReadOrdinal: UInt64 = 0
    var lastCallbackCount: UInt64?
    var lastFrameCount: UInt64?
    var lastPCMNonzeroSampleCount: UInt64?
    var lastPCMAbsoluteSampleSum: UInt64?
    var lastFailureCount: UInt64?
    var lastUnexpectedRecordingRequestCount: UInt64?
    var lastInboundAudioStatistics: WebRTCAudioStatistics?
    var lastStatisticsCollectedAt: Date?

    init(
        proofAttemptID: UUID = UUID(),
        counterWindowID: UUID = UUID(),
        scopeID: UUID,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization,
        sessionGeneration: UUID,
        audioPolicyGeneration: UUID,
        expectedPeer: WebRTCPeer,
        stage: IOSHostedCallPlayoutProofStage
    ) {
        self.proofAttemptID = proofAttemptID
        self.counterWindowID = counterWindowID
        self.scopeID = scopeID
        policyID = authorization.policyID
        origin = authorization.origin
        self.authorization = authorization
        authorizationIdentity = ObjectIdentifier(authorization)
        self.sessionGeneration = sessionGeneration
        self.audioPolicyGeneration = audioPolicyGeneration
        self.expectedPeer = expectedPeer
        expectedPeerIdentity = ObjectIdentifier(expectedPeer)
        self.stage = stage
    }
}

#if DEBUG
struct WorldwideIOSHostedCallPlayoutDebugFloor: Equatable {
    let callbackCount: UInt64
    let frameCount: UInt64
    let pcmNonzeroSampleCount: UInt64
    let pcmAbsoluteSampleSum: UInt64
    let failureCount: UInt64
    let unexpectedRecordingRequestCount: UInt64
    let statisticsCollectedAt: Date
    let inboundBytes: UInt64?
    let inboundPackets: UInt64?
    let inboundJitterBufferEmittedCount: UInt64?
    let inboundTotalSamplesReceived: UInt64?
    let inboundTotalAudioEnergy: Double?
    let inboundTotalSamplesDuration: Double?
}

struct WorldwideIOSHostedCallPlayoutDebugProjection: Equatable {
    let stage: String
    let proofAttemptID: UUID
    let counterWindowID: UUID
    let scopeID: UUID
    let policyID: UUID
    let origin: WebRTCIOSHostedCallPlayoutOrigin
    let authorizationIdentity: ObjectIdentifier
    let authorizationIsValid: Bool
    let authorizationIsRecoveryPending: Bool
    let authorizationSystemAudioGeneration: UInt64
    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
    let expectedPeerIdentity: ObjectIdentifier
    let pollOrdinal: Int
    let recoveryRequestCount: Int
    let nextRecoveryRequestPollOrdinal: Int
    let runtimeGateAdmittedAt: Date?
    let evidenceFloor: WorldwideIOSHostedCallPlayoutDebugFloor?
    let steadyFloor: WorldwideIOSHostedCallPlayoutDebugFloor?
    let timeoutPhase: String?
    let timeoutID: UUID?
    let pollingTaskIsRetained: Bool
    let timeoutTaskIsRetained: Bool
    let proofDeadlineIsArmed: Bool
    let steadyMonitorIsArmed: Bool
}
#endif

/// Process-wide owner of an authenticated worldwide WebRTC media session.
///
/// The model deliberately separates signaling/ICE, audio proof, screen presentation, and remote
/// input ownership. Each subsystem carries its own generation or authorization fence so a delayed
/// callback from a superseded task cannot mutate the active peer, reopen private screen state, or
/// deliver an input action to the wrong Mac session.
@MainActor
final class WorldwideSessionViewModel: ObservableObject {
    private static let macHostedCallChallengeAutomaticRetryDelay:
        Duration = .milliseconds(250)

    private struct MacHostedCallAnswerForwardedBinding: Equatable {
        let peerIdentity: ObjectIdentifier
        let sessionGeneration: UUID
        let negotiationGeneration: UUID
    }

    private struct MacHostedCallChallengeSendBinding: Equatable {
        let peerIdentity: ObjectIdentifier
        let sessionGeneration: UUID
        let transportAuthorizationGeneration: UUID
        let negotiationGeneration: UUID
        let challenge: WebRTCMacHostedCallChallenge
    }

    enum MediaSessionProvenance: Equatable, Sendable {
        case unauthenticated
        case authenticatedPairedCoordinatorHandoff
    }

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
    @Published private(set) var worldwideHostedCallPlayoutOracle:
        WorldwideHostedCallPlayoutOracleSnapshot?
    @Published private(set) var worldwideRawMicrophoneOracle:
        WorldwideRawMicrophoneOracleSnapshot?
    @Published private(set) var audioRequiresExplicitResume = false
    @Published private(set) var audioError: String?
    @Published private(set) var audioDiagnostic: String?
    @Published private(set) var microphoneStateText = "Off"
    @Published private(set) var microphoneError: String?
    @Published private(set) var microphoneIntentEnabled = false
    @Published private(set) var isMicrophoneSending = false
    @Published private(set) var isMicrophoneAdmissionCleanupInProgress = false
    @Published private(set) var routeText = "Unknown"
    @Published private(set) var iceStateText = "Inactive"
    @Published private(set) var remoteDisplayName = "Mac mini"
    @Published private(set) var invitationExpiresAt: Date?
    @Published private(set) var statistics: WebRTCStatisticsSnapshot?
    @Published private(set) var remoteInputCapability: WebRTCInputCapability?
    @Published private(set) var focusedInputGeneration: UInt64?
    @Published private(set) var focusedInputIsSecure = false

    private var signaling: RendezvousSignalingClient?
    private var peer: WebRTCPeer? {
        didSet {
            guard oldValue !== peer else { return }
            beginMacHostedCallNegotiationBoundary()
            transportAuthorizationGeneration = UUID()
            invalidateRawMicrophoneOracle()
            invalidateMacHostedCallEvidence(notifyLifecycle: false)
            handleIOSHostedCallPeerReplacement(
                from: oldValue,
                to: peer
            )
        }
    }
    private var rawMicrophoneContinuityTracker =
        WorldwideRawMicrophoneContinuityTracker()
    private var ordinaryPlayoutLivenessTracker =
        IOSOrdinaryPlayoutLivenessTracker()
    /// One automatic recovery per continuous fault episode. These latches deliberately survive
    /// the recovery's policy/auth rotation and reopen only after real counter advancement.
    private var microphoneAutomaticRecoveryConsumedSessionGeneration: UUID?
    private var ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration: UUID?
    private var ordinaryPlayoutAutomaticFailureWasPublished = false
    private var transportAuthorizationGeneration = UUID() {
        didSet {
            guard oldValue != transportAuthorizationGeneration else { return }
            // ICE may recover on the already-forwarded SDP without another offer. Retire sends
            // tied to the old transport generation while preserving the negotiation proof.
            retireMacHostedCallChallengeSendAttempt()
        }
    }
    private var remoteAudioTrack: WebRTCRemoteAudioTrack?
    private let audioLifecycle: WorldwideAudioLifecycleController
    private var recoveryCoordinator: ICERecoveryCoordinator?
    private var nextICERestartRequestID: UInt64 = 1
    private var iceIsConnected = false
    private var sessionTask: Task<Void, Never>?
    /// Serializes process-global WebRTC audio ownership across peer replacement. A replacement
    /// session may be accepted immediately, but it cannot open the shared audio gate until every
    /// retiring peer has completed its terminal close.
    private var sessionRetirementTask: Task<Void, Never>?
    private var sessionRetirementGeneration = UUID()
    private var peerEventTask: Task<Void, Never>?
    private var audioPlayoutProofTask: Task<Void, Never>?
    private var macHostedCallEvidenceLeaseTask: Task<Void, Never>?
    private var macHostedCallChallengeSendTask: Task<Void, Never>?
    private var macHostedCallChallengeSendAttemptID: UUID?
    private var macHostedCallChallengeSendBinding:
        MacHostedCallChallengeSendBinding?
    private var successfullySentMacHostedCallChallengeBinding:
        MacHostedCallChallengeSendBinding?
    /// Rotates before every remote offer and peer/session retirement. Transient ICE recovery keeps
    /// this generation because the already-forwarded SDP remains authoritative without a new answer.
    private var macHostedCallNegotiationGeneration = UUID()
    private var macHostedCallAnswerForwardedBinding:
        MacHostedCallAnswerForwardedBinding?
    private var currentMacHostedCallChallenge:
        WebRTCMacHostedCallChallenge?
    private var currentMacHostedCallEvidence:
        WebRTCMacHostedCallEvidence?
    private var audioPlayoutProofTimeoutTask: Task<Void, Never>?
    private var audioPlayoutRecoveryAuthorization: WebRTCIOSPlayoutRecoveryAuthorization?
    private var iosPlayoutProofAttempt: IOSPlayoutProofAttempt?
    private var iosHostedCallPlayoutProofTask: Task<Void, Never>?
    private var iosHostedCallPlayoutProofTimeoutTask: Task<Void, Never>?
    private var iosPendingStartupConnectedCallPlayout:
        IOSPendingStartupConnectedCallPlayout?
    private var iosHostedCallPlayoutAuthorization:
        WebRTCIOSHostedCallPlayoutAuthorization?
    private var iosHostedCallPlayoutAttempt:
        IOSHostedCallPlayoutProofAttempt?
    private var iosHostedCallPlayoutProofAttemptID: UUID?
    private var iosHostedCallPlayoutCounterWindowID: UUID?
    private var iosHostedCallPlayoutScopeID: UUID?
    private var iosHostedCallPlayoutPolicyID: UUID?
    /// Rotates at native interruption, recovery, and RemoteIO topology boundaries.
    private var audioPolicyGeneration = UUID() {
        didSet {
            if oldValue != audioPolicyGeneration {
                invalidateRawMicrophoneOracle()
                retireIOSHostedCallPlayoutAttempt()
            }
        }
    }
    private enum ApplicationLifecyclePhase {
        case active
        case inactive
        case background
    }

    private var verifiedAudioPolicyGeneration: UUID?
    /// Remains armed until a native recovery establishes a new floor and then observes strictly
    /// advancing callbacks and frames.
    private var audioPolicyRequiresFreshRecovery = false
    private var microphoneAuthorization: WebRTCIOSMicrophoneAuthorization?
    private var microphoneOutputOnlyToken:
        WebRTCIOSOutputOnlyMicrophoneToken?
    private var microphonePermissionTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var microphonePermissionOperationGeneration = UUID()
    private var microphoneOperationGeneration = UUID()
    private var microphonePermissionGranted = false
    private var microphoneIsBlockedByCall = false
    private var currentMicrophoneCallDisposition:
        WorldwideMicrophoneCallDisposition = .inactive
    private var microphoneAwaitsPostCallRecovery = false
    private var applicationIsActive = false
    private var lastHandledApplicationLifecyclePhase: ApplicationLifecyclePhase?
    private var preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation = false
    private var automaticMicrophoneEligibleSessionGeneration: UUID?
    private var automaticMicrophoneAttemptedSessionGeneration: UUID?
    private var manuallyDisabledMicrophoneSessionGeneration: UUID?
    /// A native admission failure is terminal for the current automatic attempt. Audio-policy
    /// snapshots continue while output-only recovery settles, so retrying from those snapshots
    /// would otherwise create an unbounded Starting/Unavailable loop.
    private var microphoneAdmissionFailedSessionGeneration: UUID?
    /// A peer-actor health race is not a terminal native admission failure. Hold the retry until
    /// the MainActor observes a newer healthy-transport proof so lifecycle snapshots cannot spin.
    private var microphoneAdmissionDeferredUntilTransportProof:
        (sessionGeneration: UUID, proofRevision: UInt64)?
    private var viewerTransportHealthProofRevision: UInt64 = 0
    private var microphoneAdmissionCleanupID: UUID?
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
    private var sessionGeneration = UUID() {
        didSet {
            if oldValue != sessionGeneration {
                beginMacHostedCallNegotiationBoundary()
                transportAuthorizationGeneration = UUID()
                invalidateRawMicrophoneOracle()
                invalidateMacHostedCallEvidence(
                    notifyLifecycle: false
                )
                retireIOSHostedCallPlayoutAttempt()
            }
        }
    }
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
    private var debugIPhoneMicrophonePermissionRequester: (@MainActor () async -> Bool)?
    private var debugIPhoneMicrophoneEnableAttemptObserver: (@MainActor () -> Void)?
    private var debugIPhoneMicrophonePermissionResolutionObserver:
        (@MainActor (Bool) -> Void)?
    private var debugIPhoneMicrophoneNativeEnableHandler:
        (@MainActor (
            WebRTCIOSMicrophoneAuthorization
        ) async throws -> Void)?
    private var debugIPhoneMicrophoneNativeDisableHandler:
        (@MainActor (
            WebRTCIOSMicrophoneAuthorization?,
            WebRTCIOSOutputOnlyMicrophoneToken?
        ) async -> Bool)?
    private var debugIPhoneMicrophoneDidCommitObserver:
        (@MainActor (WebRTCIOSMicrophoneAuthorization) -> Void)?
    private var debugIPhoneMicrophoneSenderStatisticsReader:
        (@MainActor (WebRTCPeer) async
            -> WebRTCIPhoneMicrophoneSenderStatistics?)?
    private var debugIOSPlayoutDiagnosticsReader: (
        @MainActor (WebRTCPeer) async -> WebRTCIOSPlayoutDiagnostics?
    )?
    private var debugIOSPlayoutRecoveryRequester: (
        @MainActor (WebRTCPeer, WebRTCIOSPlayoutRecoveryAuthorization) async -> Void
    )?
    private var debugIOSHostedCallPlayoutRecoveryRequester: (
        @MainActor (
            WebRTCPeer,
            WebRTCIOSHostedCallPlayoutAuthorization
        ) -> Void
    )?
    private var debugIOSHostedCallPlayoutRequestPreflightWaiter:
        (@MainActor () async -> Void)?
    private var debugIOSHostedCallPlayoutPollWaiter: (@MainActor () async -> Void)?
    private var debugIOSHostedCallPlayoutSetupTimeoutWaiter:
        (@MainActor () async -> Void)?
    private var debugIOSHostedCallPlayoutEvidenceTimeoutWaiter:
        (@MainActor () async -> Void)?
    private var debugIOSHostedCallPlayoutSteadyTimeoutWaiter:
        (@MainActor () async -> Void)?
    private var debugIOSHostedCallPlayoutClock: (@MainActor () -> Date)?
    private var debugBeforeRetiredPeerClose:
        (@MainActor () async -> Void)?

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
    private var debugMacHostedCallChallengeSender: (
        @MainActor (
            WebRTCPeer,
            WebRTCMacHostedCallChallenge
        ) async throws -> Void
    )?
    private var debugMacHostedCallChallengeAutomaticRetryWaiter:
        (@MainActor () async -> Void)?
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
            reconcileIPhoneMicrophone(for: snapshot)
        }
        audioLifecycle.onPlaybackRecoveryRequested = { [weak self] in
            guard let self else { return }
            self.beginIOSPlayoutProof(
                requestRecovery: true,
                postCallRecoveryMilestone:
                    self.audioLifecycle
                        .postCallMicrophoneRecoveryMilestone
            )
        }
        audioLifecycle.onHostedCallPlayoutRecoveryRequested = { [weak self] authorization in
            self?.beginIOSHostedCallPlayoutProof(authorization: authorization)
        }
        audioLifecycle.onHostedCallPlayoutRecoveryResumed = {
            [weak self] authorization in
            self?.resumeIOSHostedCallPlayoutProof(
                authorization: authorization
            )
        }

        audioLifecycle.onPlayoutProofRefreshRequested = { [weak self] in
            guard let self else { return }
            let hostedCallPolicyWasOwned = hasOwnedIOSHostedCallPlayoutPolicy
            invalidateAudioPolicyProof(requiresFreshRecovery: false)
            guard !hostedCallPolicyWasOwned else { return }
            beginIOSPlayoutProof(requestRecovery: false)
        }
        audioLifecycle.onAmbiguousCategoryPlayoutProofRefreshRequested = {
            [weak self] claim in
            guard let self else { return }
            let hostedCallPolicyWasOwned = hasOwnedIOSHostedCallPlayoutPolicy
            invalidateAudioPolicyProof(requiresFreshRecovery: false)
            guard !hostedCallPolicyWasOwned else { return }
            beginIOSPlayoutProof(
                requestRecovery: false,
                categoryProofClaim: claim
            )
        }
        audioLifecycle.onMicrophoneCallDispositionChanged = {
            [weak self] disposition in
            self?.microphoneCallDispositionChanged(disposition)
        }
        audioLifecycle.onMacHostedCallChallengeChanged = {
            [weak self] challenge in
            self?.macHostedCallChallengeChanged(challenge)
        }
        audioLifecycle.onPostCallRecoveryCompleted = { [weak self] in
            self?.postCallAudioRecoveryCompleted()
        }
        audioLifecycle.onAudioProofInvalidated = { [weak self] requiresFreshRecovery in
            self?.suspendIPhoneMicrophone(
                stateText: "Paused — audio recovery required",
                preserveIntent: true,
                reprovePlayout: false
            )
            self?.invalidateAudioPolicyProof(
                requiresFreshRecovery: requiresFreshRecovery
            )
        }
    }

    // MARK: - Published capabilities

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

    var canToggleIPhoneMicrophone: Bool {
        hasActiveSession
            && peer != nil
            && !isMicrophoneAdmissionCleanupInProgress
    }

    var iPhoneMicrophoneButtonTitle: String {
        if microphoneAdmissionFailedSessionGeneration == sessionGeneration {
            return "Retry iPhone Microphone"
        }
        return microphoneIntentEnabled
            ? "Turn Off iPhone Microphone"
            : "Use iPhone Microphone"
    }

    var iPhoneMicrophoneButtonSystemImage: String {
        if microphoneAdmissionFailedSessionGeneration == sessionGeneration {
            return "arrow.clockwise"
        }
        return microphoneIntentEnabled ? "mic.slash.fill" : "mic.fill"
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
            provenance: .unauthenticated,
            beforeAudioActivation: beforeAudioActivation
        )
    }
    #endif

    // MARK: - Media session lifecycle

    /// Starts ordinary WebRTC signaling only after bootstrap/availability produced a fresh,
    /// one-use session client. Pairing secrets never enter this media lifecycle.
    @discardableResult
    func connect(
        signalingClient client: RendezvousSignalingClient,
        provenance: MediaSessionProvenance = .unauthenticated,
        beforeAudioActivation: @MainActor () -> Void = {}
    ) -> Bool {
        guard !isConnecting, !hasActiveSession else { return false }

        // Validation is complete. Rotate every session-owned fence before lifecycle preparation so
        // a startup-connected-call authorization cannot bind to the retired media generation.
        beforeAudioActivation()
        resetPublishedSessionState()
        sessionGeneration = UUID()
        audioPolicyGeneration = UUID()
        isConnecting = true
        stateText = "Connecting securely"
        signaling = client
        automaticMicrophoneEligibleSessionGeneration =
            provenance == .authenticatedPairedCoordinatorHandoff ? sessionGeneration : nil
        automaticMicrophoneAttemptedSessionGeneration = nil
        manuallyDisabledMicrophoneSessionGeneration = nil
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneAdmissionDeferredUntilTransportProof = nil
        viewerTransportHealthProofRevision = 0
        microphoneAdmissionCleanupID = nil
        isMicrophoneAdmissionCleanupInProgress = false
        rawMicrophoneContinuityTracker.reset()
        ordinaryPlayoutLivenessTracker.reset()
        microphoneAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticFailureWasPublished = false
        nextICERestartRequestID = 1
        hasHandledRemoteOffer = false
        recoveryProofEpoch = 0
        recoveryProofRequired = false
        restartAnswerAwaitingSendEpoch = nil
        pendingRecoveryProbe = nil
        let generation = sessionGeneration
        if let pendingRetirement = sessionRetirementTask {
            let retirementGeneration = sessionRetirementGeneration
            sessionTask = Task { @MainActor [weak self] in
                await pendingRetirement.value
                guard let self,
                      !Task.isCancelled,
                      sessionGeneration == generation,
                      signaling != nil else { return }
                if sessionRetirementGeneration == retirementGeneration {
                    sessionRetirementTask = nil
                }
                audioLifecycle.prepare(serverName: remoteDisplayName)
                await runSession(client: client, generation: generation)
            }
        } else {
            audioLifecycle.prepare(serverName: remoteDisplayName)
            sessionTask = Task { [weak self] in
                await self?.runSession(client: client, generation: generation)
            }
        }
        return true
    }

    private func iOSPlayoutInputPolicyMatches(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        let expectsMicrophone =
            microphoneIntentEnabled
                && microphoneAuthorization?.isValid == true
                && !microphoneIsBlockedByCall
        return diagnostics.inputBusEnabled == expectsMicrophone
    }

    private func iOSPlayoutRouteInvariantsHold(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        iOSPlayoutInputPolicyMatches(diagnostics)
            && WorldwideAudioPlayoutOracleSnapshot.routeInvariantsHold(diagnostics)
    }

    private func iOSPlayoutCategoryProofPolicyMatches(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        claim: WorldwideAudioCategoryProofClaim?
    ) -> Bool {
        guard let claim else { return true }
        guard claim.mode == AVAudioSession.Mode.default.rawValue,
              diagnostics.modeIsDefault else { return false }

        if claim.category
            == AVAudioSession.Category.playAndRecord.rawValue {
            guard claim.categoryOptionsRawValue
                    == AVAudioSession.CategoryOptions
                        .defaultToSpeaker
                        .union(.allowBluetoothA2DP)
                        .rawValue,
                  diagnostics.inputBusEnabled,
                  diagnostics.categoryIsMediaPlayAndRecord,
                  !diagnostics.categoryIsMediaPlayback,
                  diagnostics.categoryOptionsAreIPhoneMicrophoneRouting,
                  !diagnostics.categoryOptionsAreEmpty,
                  !diagnostics.categoryOptionsAreMixWithOthers,
                  diagnostics.captureRouteIsBuiltInMicrophone,
                  diagnostics.captureRouteProofGeneration > 0,
                  microphoneAuthorization?.isValid == true else {
                return false
            }
            return true
        }

        guard claim.category
                == AVAudioSession.Category.playback.rawValue,
              claim.categoryOptionsRawValue == 0,
              !diagnostics.inputBusEnabled,
              diagnostics.categoryIsMediaPlayback,
              !diagnostics.categoryIsMediaPlayAndRecord,
              diagnostics.categoryOptionsAreEmpty,
              !diagnostics.categoryOptionsAreIPhoneMicrophoneRouting,
              !diagnostics.categoryOptionsAreMixWithOthers else {
            return false
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
        guard lastHandledApplicationLifecyclePhase != .active else {
            return
        }
        lastHandledApplicationLifecyclePhase = .active
        applicationIsActive = true
        recoverPassiveAudioLifecyclePreservingEstablishedMicrophone {
            audioLifecycle.appBecameActive()
        }
        establishAutomaticIPhoneMicrophoneIntentIfEligible()
        continueIPhoneMicrophoneEnablementIfPossible()
    }

    func handleAppBecameInactive() {
        guard lastHandledApplicationLifecyclePhase != .inactive else {
            return
        }
        lastHandledApplicationLifecyclePhase = .inactive
        applicationIsActive = false
        pausePendingIPhoneMicrophoneForInactiveApp()
        audioLifecycle.appBecameInactive()
        hideScreenForPassiveLifecycleIfNeeded()
    }

    func handleAppEnteredBackground() {
        guard lastHandledApplicationLifecyclePhase != .background else {
            return
        }
        lastHandledApplicationLifecyclePhase = .background
        applicationIsActive = false
        pausePendingIPhoneMicrophoneForInactiveApp()
        recoverPassiveAudioLifecyclePreservingEstablishedMicrophone {
            audioLifecycle.appEnteredBackground()
        }
        hideScreenForPassiveLifecycleIfNeeded()
    }

    private func recoverPassiveAudioLifecyclePreservingEstablishedMicrophone(
        _ recovery: () -> Void
    ) {
        let authorization = microphoneAuthorization
        preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation =
            isMicrophoneSending && authorization?.isValid == true
        defer {
            preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation = false
        }
        recovery()
    }

    private func pausePendingIPhoneMicrophoneForInactiveApp() {
        guard !isMicrophoneSending else { return }

        if microphoneAuthorization != nil {
            suspendIPhoneMicrophone(
                stateText: "Paused — waiting for app",
                preserveIntent: true,
                reprovePlayout: false
            )
        } else if microphoneIntentEnabled {
            microphoneStateText = "Paused — waiting for app"
        }
    }

    func resumeAudioPlayback() {
        ordinaryPlayoutLivenessTracker.reset()
        ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticFailureWasPublished = false
        audioLifecycle.resumePlayback()
    }

    func toggleIPhoneMicrophone() {
        guard !isMicrophoneAdmissionCleanupInProgress else { return }

        if microphoneAdmissionFailedSessionGeneration == sessionGeneration {
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphoneAutomaticRecoveryConsumedSessionGeneration = nil
            rawMicrophoneContinuityTracker.reset()
            microphoneError = nil
            microphoneStateText = "Starting"
            continueIPhoneMicrophoneEnablementIfPossible()
            return
        }

        if microphoneIntentEnabled {
            manuallyDisabledMicrophoneSessionGeneration = sessionGeneration
            automaticMicrophoneAttemptedSessionGeneration = sessionGeneration
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphoneAutomaticRecoveryConsumedSessionGeneration = nil
            rawMicrophoneContinuityTracker.reset()
            microphoneError = nil
            suspendIPhoneMicrophone(
                stateText: "Off",
                preserveIntent: false,
                reprovePlayout: true
            )
            return
        }

        manuallyDisabledMicrophoneSessionGeneration = nil
        if automaticMicrophoneEligibleSessionGeneration == sessionGeneration {
            automaticMicrophoneAttemptedSessionGeneration = sessionGeneration
        }
        microphoneIntentEnabled = true
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneAdmissionDeferredUntilTransportProof = nil
        microphoneAutomaticRecoveryConsumedSessionGeneration = nil
        rawMicrophoneContinuityTracker.reset()
        microphoneError = nil
        continueIPhoneMicrophoneEnablementIfPossible()
    }

    private func establishAutomaticIPhoneMicrophoneIntentIfEligible() {
        let generation = sessionGeneration
        guard automaticMicrophoneEligibleSessionGeneration == generation,
              automaticMicrophoneAttemptedSessionGeneration != generation,
              manuallyDisabledMicrophoneSessionGeneration != generation,
              applicationIsActive,
              !recoveryProofRequired,
              peer != nil,
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady else {
            return
        }

        automaticMicrophoneAttemptedSessionGeneration = generation
        microphoneIntentEnabled = true
        microphoneError = nil
    }

    private func continueIPhoneMicrophoneEnablementIfPossible() {
        guard microphoneIntentEnabled else { return }
        guard !microphoneAwaitsPostCallRecovery else {
            microphoneStateText = "Paused — restoring microphone"
            return
        }
        guard !microphoneIsBlockedByCall,
              audioLifecycle.microphoneActivationIsAllowed() else {
            microphoneStateText = "Muted — iPhone call active"
            return
        }

        guard applicationIsActive else {
            microphoneStateText = "Paused — waiting for app"
            return
        }

        if microphonePermissionGranted {
            reconcileIPhoneMicrophone()
            return
        }

        guard microphonePermissionTask == nil else { return }

        microphoneStateText = "Requesting permission"
        let permissionGeneration = UUID()
        let expectedSessionGeneration = sessionGeneration
        microphonePermissionOperationGeneration = permissionGeneration
        microphonePermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.requestIPhoneMicrophonePermission()
            guard !Task.isCancelled,
                  self.microphonePermissionOperationGeneration == permissionGeneration,
                  self.sessionGeneration == expectedSessionGeneration,
                  self.microphoneIntentEnabled else {
                return
            }
            #if DEBUG
            defer {
                self.debugIPhoneMicrophonePermissionResolutionObserver?(granted)
            }
            #endif
            self.microphonePermissionTask = nil

            guard granted else {
                self.handleIPhoneMicrophonePermissionDenied()
                return
            }

            self.microphonePermissionGranted = true
            guard self.applicationIsActive else {
                self.microphoneStateText = "Paused — waiting for app"
                return
            }
            guard !self.microphoneIsBlockedByCall,
                  self.audioLifecycle.microphoneActivationIsAllowed() else {
                self.microphoneStateText = "Muted — iPhone call active"
                return
            }
            self.microphoneStateText = "Starting"
            self.reconcileIPhoneMicrophone()
        }
    }

    private func requestIPhoneMicrophonePermission() async -> Bool {
        #if DEBUG
        if let requester = debugIPhoneMicrophonePermissionRequester {
            return await requester()
        }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func handleIPhoneMicrophonePermissionDenied() {
        microphonePermissionGranted = false
        suspendIPhoneMicrophone(
            stateText: "Permission denied",
            preserveIntent: false,
            reprovePlayout: true
        )
        microphoneError =
            "Allow microphone access in Settings before enabling the iPhone microphone."
    }

    private func reconcileIPhoneMicrophone(
        for audioSnapshot: WorldwideAudioLifecycleSnapshot? = nil
    ) {
        if let audioSnapshot,
           audioSnapshot.errorText != nil,
           microphoneAuthorization != nil {
            suspendIPhoneMicrophone(
                stateText: "Paused — audio unavailable",
                preserveIntent: true,
                reprovePlayout: false
            )
            return
        }

        guard microphoneIntentEnabled else {
            if microphoneAuthorization == nil {
                microphoneStateText = "Off"
            }
            return
        }
        guard microphonePermissionGranted else { return }
        guard !microphoneAwaitsPostCallRecovery else {
            microphoneStateText = "Paused — restoring microphone"
            return
        }
        guard !microphoneIsBlockedByCall,
              audioLifecycle.microphoneActivationIsAllowed() else {
            microphoneStateText = "Muted — iPhone call active"
            return
        }
        if microphoneAuthorization?.isValid == true {
            if !isMicrophoneSending {
                microphoneStateText = "Starting"
            }
            return
        }
        guard applicationIsActive else {
            microphoneStateText = "Paused — waiting for app"
            return
        }
        guard !isMicrophoneAdmissionCleanupInProgress else {
            microphoneStateText = "Recovering audio"
            return
        }
        guard microphoneAdmissionDeferredUntilTransportProof?
            .sessionGeneration != sessionGeneration else {
            microphoneStateText = "Paused — waiting for healthy connection"
            return
        }
        guard microphoneAdmissionFailedSessionGeneration != sessionGeneration else {
            if microphoneAuthorization == nil {
                microphoneStateText = "Unavailable"
            }
            return
        }
        guard canViewScreen,
              let expectedPeer = peer else {
            microphoneStateText = "Paused — waiting for healthy connection"
            return
        }

        let operationGeneration = UUID()
        let expectedSessionGeneration = sessionGeneration
        let authorization = WebRTCIOSMicrophoneAuthorization()
        invalidateRawMicrophoneOracle()
        if let outputOnlyToken = microphoneOutputOnlyToken {
            audioLifecycle.revokeIPhoneMicrophoneOutputOnlyTransition(
                outputOnlyToken
            )
            if outputOnlyToken.state != .executing {
                microphoneOutputOnlyToken = nil
            }
        }
        microphoneOperationGeneration = operationGeneration
        microphoneAuthorization?.revoke()
        microphoneAuthorization = authorization
        isMicrophoneSending = false
        microphoneStateText = "Starting"
        guard audioLifecycle.beginMicrophoneTopologyTransition(
            isEnabled: true
        ) != 0 else {
            authorization.revoke()
            microphoneAuthorization = nil
            microphoneTask?.cancel()
            microphoneTask = nil
            microphoneStateText =
                "Paused — waiting for audio policy"
            return
        }
        invalidateAudioPolicyProof(requiresFreshRecovery: false)

        microphoneTask?.cancel()
        microphoneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                debugIPhoneMicrophoneEnableAttemptObserver?()
                #endif
                try await self.performIPhoneMicrophoneEnable(
                    on: expectedPeer,
                    authorization: authorization
                )
            } catch {
                authorization.revoke()
                guard microphoneOperationGeneration == operationGeneration,
                      sessionGeneration == expectedSessionGeneration,
                      peer === expectedPeer,
                      microphoneAuthorization === authorization else {
                    _ = await self.performIPhoneMicrophoneDisable(
                        on: expectedPeer,
                        authorization: authorization
                    )
                    return
                }
                self.invalidateRawMicrophoneOracle()
                let shouldDeferUntilTransportProof =
                    (error as? WebRTCTransportError) == .transportNotHealthy
                let transportProofRevisionAtFailure =
                    viewerTransportHealthProofRevision
                let outputOnlyToken =
                    armIPhoneMicrophoneOutputOnlyToken(
                        ownerEpoch: expectedSessionGeneration
                    )
                let cleanupID = UUID()
                microphoneAdmissionCleanupID = cleanupID
                isMicrophoneAdmissionCleanupInProgress = true
                microphoneAdmissionFailedSessionGeneration = nil
                if shouldDeferUntilTransportProof {
                    microphoneAdmissionDeferredUntilTransportProof = (
                        expectedSessionGeneration,
                        transportProofRevisionAtFailure
                    )
                } else {
                    microphoneAdmissionDeferredUntilTransportProof = nil
                }
                microphoneAuthorization = nil
                isMicrophoneSending = false
                microphoneStateText = "Recovering audio"
                microphoneError = error.localizedDescription
                _ = await self.performIPhoneMicrophoneDisable(
                    on: expectedPeer,
                    authorization: authorization,
                    outputOnlyToken: outputOnlyToken
                )
                clearIPhoneMicrophoneOutputOnlyToken(
                    outputOnlyToken
                )
                guard microphoneAdmissionCleanupID == cleanupID else {
                    return
                }
                microphoneAdmissionCleanupID = nil
                isMicrophoneAdmissionCleanupInProgress = false
                guard microphoneOperationGeneration == operationGeneration,
                      sessionGeneration == expectedSessionGeneration,
                      peer === expectedPeer,
                      microphoneAuthorization == nil else {
                    // This exact cleanup has retired, but a call or recovery may have replaced its
                    // operation generation while it was suspended. Re-evaluate the current owned
                    // intent so a one-shot post-call completion cannot be lost to stale cleanup.
                    reconcileIPhoneMicrophone()
                    return
                }
                if shouldDeferUntilTransportProof {
                    microphoneStateText =
                        "Paused — waiting for healthy connection"
                    if viewerTransportHealthProofRevision
                        > transportProofRevisionAtFailure,
                       canViewScreen {
                        microphoneAdmissionDeferredUntilTransportProof = nil
                        microphoneError = nil
                        microphoneStateText = "Starting"
                    }
                } else {
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                }
                beginIOSPlayoutProof(requestRecovery: true)
                if shouldDeferUntilTransportProof,
                   microphoneAdmissionDeferredUntilTransportProof == nil {
                    reconcileIPhoneMicrophone()
                }
                return
            }

            // CallKit's live aggregate is sampled synchronously and may reenter this view model,
            // revoke this authorization, rotate operation ownership, and install the call-privacy
            // rollback fence. Sample first, then prove that this task still owns admission before
            // it is allowed to mutate lifecycle category ownership.
            let microphoneActivationIsAllowed =
                audioLifecycle.microphoneActivationIsAllowed()
            guard microphoneOperationGeneration == operationGeneration,
                  sessionGeneration == expectedSessionGeneration,
                  peer === expectedPeer,
                  microphoneAuthorization === authorization else {
                authorization.revoke()
                _ = await self.performIPhoneMicrophoneDisable(
                    on: expectedPeer,
                    authorization: authorization
                )
                return
            }
            guard authorization.isValid,
                  applicationIsActive,
                  microphoneActivationIsAllowed,
                  microphoneIntentEnabled,
                  !microphoneIsBlockedByCall else {
                let outputOnlyToken =
                    armIPhoneMicrophoneOutputOnlyToken(
                        ownerEpoch: expectedSessionGeneration
                    )
                authorization.revoke()
                _ = await self.performIPhoneMicrophoneDisable(
                    on: expectedPeer,
                    authorization: authorization,
                    outputOnlyToken: outputOnlyToken
                )
                clearIPhoneMicrophoneOutputOnlyToken(
                    outputOnlyToken
                )
                return
            }
            invalidateRawMicrophoneOracle()
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            isMicrophoneSending = true
            microphoneStateText = "On"
            microphoneError = nil
            #if DEBUG
            debugIPhoneMicrophoneDidCommitObserver?(authorization)
            #endif
            beginIOSPlayoutProof(requestRecovery: false)
        }
    }

    private func performIPhoneMicrophoneEnable(
        on peer: WebRTCPeer,
        authorization: WebRTCIOSMicrophoneAuthorization
    ) async throws {
        #if DEBUG
        if let handler = debugIPhoneMicrophoneNativeEnableHandler {
            try await handler(authorization)
            return
        }
        #endif
        try await peer.enableIPhoneMicrophone(
            authorization: authorization
        )
    }

    @discardableResult
    private func performIPhoneMicrophoneDisable(
        on peer: WebRTCPeer,
        authorization: WebRTCIOSMicrophoneAuthorization?,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken? = nil
    ) async -> Bool {
        #if DEBUG
        if let handler = debugIPhoneMicrophoneNativeDisableHandler {
            return await handler(
                authorization,
                outputOnlyToken
            )
        }
        #endif
        return await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: outputOnlyToken
        )
    }

    private func suspendIPhoneMicrophone(
        stateText: String,
        preserveIntent: Bool,
        reprovePlayout: Bool,
        performNativeTeardown: Bool = true
    ) {
        invalidateRawMicrophoneOracle()
        if !microphoneIsBlockedByCall,
           preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation,
           isMicrophoneSending,
           microphoneAuthorization?.isValid == true {
            preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation = false
            if peer != nil {
                invalidateAudioPolicyProof(
                    requiresFreshRecovery: false
                )
            }
            return
        }

        if !preserveIntent {
            microphoneIntentEnabled = false
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphonePermissionOperationGeneration = UUID()
            microphonePermissionTask?.cancel()
            microphonePermissionTask = nil
        }
        let authorization = microphoneAuthorization
        let expectedPeer = peer
        let expectedSessionGeneration = sessionGeneration
        let topologyMayChange = authorization != nil || isMicrophoneSending
        let outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken?
        if topologyMayChange, performNativeTeardown {
            outputOnlyToken = armIPhoneMicrophoneOutputOnlyToken(
                ownerEpoch: expectedSessionGeneration
            )
        } else {
            outputOnlyToken = nil
            if !performNativeTeardown,
               let queuedToken = microphoneOutputOnlyToken {
                audioLifecycle
                    .revokeIPhoneMicrophoneOutputOnlyTransition(
                        queuedToken
                    )
                if queuedToken.state == .revoked {
                    microphoneOutputOnlyToken = nil
                }
            }
        }
        authorization?.revoke()
        microphoneAuthorization = nil
        microphoneOperationGeneration = UUID()
        microphoneTask?.cancel()
        microphoneTask = nil
        isMicrophoneSending = false
        microphoneStateText = stateText

        guard topologyMayChange, let expectedPeer else { return }
        guard performNativeTeardown else { return }
        invalidateAudioPolicyProof(requiresFreshRecovery: false)
        microphoneTask = Task { @MainActor [weak self] in
            _ = await self?.performIPhoneMicrophoneDisable(
                on: expectedPeer,
                authorization: authorization,
                outputOnlyToken: outputOnlyToken
            )
            guard let self else { return }
            clearIPhoneMicrophoneOutputOnlyToken(outputOnlyToken)
            guard
                  sessionGeneration == expectedSessionGeneration,
                  peer === expectedPeer else {
                return
            }
            if reprovePlayout {
                beginIOSPlayoutProof(requestRecovery: false)
            }
        }
    }

    private func armIPhoneMicrophoneOutputOnlyToken(
        ownerEpoch: UUID
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        if let existingToken = microphoneOutputOnlyToken {
            audioLifecycle.revokeIPhoneMicrophoneOutputOnlyTransition(
                existingToken
            )
            guard existingToken.state != .executing else {
                return nil
            }
            microphoneOutputOnlyToken = nil
        }
        let token =
            audioLifecycle.beginIPhoneMicrophoneOutputOnlyTransition(
                ownerEpoch: ownerEpoch
            )
        microphoneOutputOnlyToken = token
        return token
    }

    private func clearIPhoneMicrophoneOutputOnlyToken(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken?
    ) {
        guard let token else { return }
        if microphoneOutputOnlyToken === token {
            microphoneOutputOnlyToken = nil
        }
        audioLifecycle
            .iPhoneMicrophoneOutputOnlyTransitionDidComplete(token)
    }

    // MARK: - Screen presentation ownership

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

    // MARK: - Remote input serialization

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

    // MARK: - Signaling and peer events

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
            let newPeerIdentity = ObjectIdentifier(newPeer)
            await newPeer.installIPhoneMicrophoneTransportSuspensionHandler {
                [weak self] retirementContext in
                guard let self else { return nil }
                return prepareIPhoneMicrophoneForTransportSuspension(
                    retirementContext: retirementContext,
                    expectedPeerIdentity: newPeerIdentity,
                    expectedSessionGeneration: generation
                )
            }
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
                // Close the challenge lane before the peer begins applying a replacement offer.
                // Native transport callbacks may still look healthy while the peer is suspended
                // inside setRemoteDescription; only this offer's forwarded answer may reopen it.
                beginMacHostedCallNegotiationBoundary()
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
            // The peer installs the viewer's bidirectional Mac-hosted-call capability
            // immediately before announcing its answer. Preserve this event-stream order: only
            // after the answer reaches signaling may the still-current challenge touch the data
            // channel. Native connected/ICE/data-open callbacks are allowed to arrive earlier.
            let sourceNegotiationGeneration =
                macHostedCallNegotiationGeneration
            do {
                try await signaling.send(payload)
                guard generation == sessionGeneration,
                      self.signaling === signaling,
                      peer === sourcePeer else {
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
                if case .answer = payload {
                    macHostedCallAnswerWasForwardedIfCurrent(
                        sourcePeer: sourcePeer,
                        sourceGeneration: generation,
                        sourceNegotiationGeneration:
                            sourceNegotiationGeneration
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

        case .macHostedCallChallengeReceived:
            // Only the Mac host receives viewer-originated challenges.
            break

        case .macHostedCallEvidenceChanged(let evidence):
            handleMacHostedCallEvidence(
                evidence,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
            )

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
            if !ordinaryIOSPlayoutProofIsSuppressedByHostedCall {
                beginIOSPlayoutProof(requestRecovery: false)
            }

        case .remoteVideoTrack(let track):
            remoteVideoTrack = track
            if isScreenVisible {
                stateText = "Screen live"
            }

        case .routeChanged(let route):
            routeText = route.kind.displayText

        case .statistics(let snapshot):
            await handleWorldwideSessionStatistics(
                snapshot,
                from: sourcePeer,
                generation: generation
            )

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
            retireIOSHostedCallPlayoutAttempt()
            isPeerConnected = false
            markTransportUncertain("Recovering secure media")
            await recoveryCoordinator?.iceStateChanged(.disconnected)
        case .failed:
            retireIOSHostedCallPlayoutAttempt()
            isPeerConnected = false
            markTransportUncertain("Recovering secure media")
            await recoveryCoordinator?.iceStateChanged(.failed)
        case .closed:
            retireIOSHostedCallPlayoutAttempt()
            if hasActiveSession {
                failSession("The secure media connection closed.", generation: generation)
            }
        }
    }

    private func handleWorldwideSessionStatistics(
        _ snapshot: WebRTCStatisticsSnapshot,
        from sourcePeer: WebRTCPeer,
        generation: UUID
    ) async {
        guard generation == sessionGeneration,
              peer === sourcePeer else { return }

        statistics = snapshot
        if hasOwnedIOSHostedCallPlayoutPolicy {
            await refreshIOSHostedCallPlayoutProof(
                from: sourcePeer,
                generation: generation,
                statistics: snapshot
            )
        } else if !ordinaryIOSPlayoutProofIsSuppressedByHostedCall {
            await refreshIOSPlayoutOracle(
                from: sourcePeer,
                generation: generation,
                statistics: snapshot
            )
            refreshIOSPlayoutProof()
        }
        await refreshIOSRawMicrophoneOracle(
            from: sourcePeer,
            generation: generation
        )
    }

    private func refreshIOSRawMicrophoneOracle(
        from sourcePeer: WebRTCPeer,
        generation: UUID
    ) async {
        guard automaticMicrophoneEligibleSessionGeneration
                == generation,
              generation == sessionGeneration,
              peer === sourcePeer,
              microphoneIntentEnabled,
              microphonePermissionGranted,
              isMicrophoneSending,
              !microphoneAwaitsPostCallRecovery,
              !microphoneIsBlockedByCall,
              audioLifecycle.microphoneActivationIsAllowed(),
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady,
              !recoveryProofRequired,
              let authorization = microphoneAuthorization,
              authorization.isValid,
              authorization.recordingGeneration > 0 else {
            invalidateRawMicrophoneOracle()
            return
        }

        let expectedAudioPolicyGeneration =
            audioPolicyGeneration
        let expectedTransportAuthorizationGeneration =
            transportAuthorizationGeneration
        let expectedAuthorizationIdentity =
            ObjectIdentifier(authorization)
        guard let exactStatistics =
            await readIPhoneMicrophoneSenderStatistics(
                from: sourcePeer
            ) else {
            invalidateRawMicrophoneOracle()
            return
        }

        guard automaticMicrophoneEligibleSessionGeneration
                == generation,
              generation == sessionGeneration,
              peer === sourcePeer,
              audioPolicyGeneration
                == expectedAudioPolicyGeneration,
              transportAuthorizationGeneration
                == expectedTransportAuthorizationGeneration,
              microphoneIntentEnabled,
              microphonePermissionGranted,
              isMicrophoneSending,
              !microphoneAwaitsPostCallRecovery,
              !microphoneIsBlockedByCall,
              audioLifecycle.microphoneActivationIsAllowed(),
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady,
              !recoveryProofRequired,
              microphoneAuthorization === authorization,
              ObjectIdentifier(authorization)
                == expectedAuthorizationIdentity,
              authorization.isValid,
              authorization.recordingGeneration
                == exactStatistics.sender.recordingGeneration,
              exactStatistics.sender.recordingGeneration
                == exactStatistics.sender
                    .approvedRecordingGeneration,
              exactStatistics.sender
                .captureRouteIsBuiltInMicrophone,
              exactStatistics.sender
                .captureRouteProofGeneration > 0 else {
            invalidateRawMicrophoneOracle()
            return
        }

        let sample = WorldwideRawMicrophoneProofSample(
            sessionGeneration: generation,
            peerIdentity: ObjectIdentifier(sourcePeer),
            transportAuthorizationGeneration:
                expectedTransportAuthorizationGeneration,
            audioPolicyGeneration:
                expectedAudioPolicyGeneration,
            authorizationIdentity:
                expectedAuthorizationIdentity,
            authenticatedPairedSession: true,
            microphoneIntentIsCurrent: true,
            microphonePermissionGranted: true,
            callIsActive:
                currentMicrophoneCallDisposition != .inactive,
            macHostedCallEvidenceAdmitted:
                currentMicrophoneCallDisposition == .macHosted,
            transportIsHealthy: true,
            statistics: exactStatistics
        )
        switch rawMicrophoneContinuityTracker.observe(sample) {
        case .waiting:
            worldwideRawMicrophoneOracle = nil
        case .satisfied(let oracle):
            worldwideRawMicrophoneOracle = oracle
            microphoneAutomaticRecoveryConsumedSessionGeneration = nil
        case .stalled:
            worldwideRawMicrophoneOracle = nil
            recoverFromStalledIPhoneMicrophone(generation: generation)
        case .rejected:
            worldwideRawMicrophoneOracle = nil
        }
    }

    private func recoverFromStalledIPhoneMicrophone(generation: UUID) {
        guard generation == sessionGeneration,
              microphoneIntentEnabled,
              isMicrophoneSending else { return }

        if microphoneAutomaticRecoveryConsumedSessionGeneration
            == generation {
            microphoneAdmissionFailedSessionGeneration = generation
            microphoneStateText = "Unavailable"
            microphoneError =
                "The iPhone microphone stopped delivering audio after automatic recovery. Tap Retry iPhone Microphone."
            suspendIPhoneMicrophone(
                stateText: "Unavailable",
                preserveIntent: true,
                reprovePlayout: true
            )
            return
        }

        guard audioLifecycle.requestAutomaticRuntimeAudioRecovery() else {
            return
        }
        microphoneAutomaticRecoveryConsumedSessionGeneration = generation
        microphoneStateText = "Recovering audio"
        microphoneError = nil
    }

    private func readIPhoneMicrophoneSenderStatistics(
        from sourcePeer: WebRTCPeer
    ) async -> WebRTCIPhoneMicrophoneSenderStatistics? {
        #if DEBUG
        if let reader =
            debugIPhoneMicrophoneSenderStatisticsReader {
            return await reader(sourcePeer)
        }
        #endif
        return await sourcePeer
            .iPhoneMicrophoneSenderStatistics()
    }

    private func invalidateRawMicrophoneOracle() {
        rawMicrophoneContinuityTracker.reset()
        worldwideRawMicrophoneOracle = nil
    }

    private func failSession(_ message: String, generation: UUID) {
        guard generation == sessionGeneration else { return }
        tearDown(reason: .protocolError)
        resetPublishedSessionState()
        stateText = "Connection failed"
        lastError = message
    }

    private func tearDown(reason: RemoteSessionEndReason) {
        invalidateRawMicrophoneOracle()
        ordinaryPlayoutLivenessTracker.reset()
        microphoneAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticFailureWasPublished = false
        retireIOSHostedCallPlayoutAttempt()
        retireIOSPlayoutRecoveryAttempt()
        if let microphoneOutputOnlyToken {
            audioLifecycle.revokeIPhoneMicrophoneOutputOnlyTransition(
                microphoneOutputOnlyToken
            )
            self.microphoneOutputOnlyToken = nil
        }
        microphonePermissionTask?.cancel()
        microphonePermissionTask = nil
        microphonePermissionOperationGeneration = UUID()
        microphoneAuthorization?.revoke()
        microphoneAuthorization = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        microphoneOperationGeneration = UUID()
        microphoneIntentEnabled = false
        isMicrophoneSending = false
        microphoneAwaitsPostCallRecovery = false
        microphoneStateText = "Off"
        microphoneError = nil
        automaticMicrophoneEligibleSessionGeneration = nil
        automaticMicrophoneAttemptedSessionGeneration = nil
        manuallyDisabledMicrophoneSessionGeneration = nil
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneAdmissionDeferredUntilTransportProof = nil
        viewerTransportHealthProofRevision = 0
        microphoneAdmissionCleanupID = nil
        isMicrophoneAdmissionCleanupInProgress = false
        microphoneOutputOnlyToken = nil
        audioLifecycle.stop()
        audioPolicyGeneration = UUID()
        verifiedAudioPolicyGeneration = nil
        audioPolicyRequiresFreshRecovery = false
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
        let precedingRetirement = sessionRetirementTask
        sessionRetirementGeneration = UUID()
        #if DEBUG
        let beforeRetiredPeerClose = debugBeforeRetiredPeerClose
        #endif
        sessionTask = nil
        peerEventTask = nil
        audioPlayoutProofTask = nil
        signaling = nil
        peer = nil
        iceIsConnected = false
        nextICERestartRequestID = 1

        let retirementTask = Task { @MainActor in
            await precedingRetirement?.value
            #if DEBUG
            await beforeRetiredPeerClose?()
            #endif
            await oldPeer?.close(reason: reason)
            await oldRecoveryCoordinator?.cancel()
            await oldSignaling?.close()
        }
        sessionRetirementTask = retirementTask
    }

    private func resetPublishedSessionState() {
        ordinaryPlayoutLivenessTracker.reset()
        microphoneAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = nil
        ordinaryPlayoutAutomaticFailureWasPublished = false
        invalidateMacHostedCallEvidence(notifyLifecycle: false)
        beginMacHostedCallNegotiationBoundary()
        currentMacHostedCallChallenge = nil
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
        worldwideHostedCallPlayoutOracle = nil
        invalidateRawMicrophoneOracle()
        audioRequiresExplicitResume = false
        audioError = nil
        audioDiagnostic = nil
        microphoneStateText = "Off"
        microphoneError = nil
        microphoneIntentEnabled = false
        isMicrophoneSending = false
        microphoneIsBlockedByCall = false
        currentMicrophoneCallDisposition = .inactive
        microphoneAwaitsPostCallRecovery = false
        automaticMicrophoneEligibleSessionGeneration = nil
        automaticMicrophoneAttemptedSessionGeneration = nil
        manuallyDisabledMicrophoneSessionGeneration = nil
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneAdmissionDeferredUntilTransportProof = nil
        viewerTransportHealthProofRevision = 0
        microphoneAdmissionCleanupID = nil
        isMicrophoneAdmissionCleanupInProgress = false
        microphoneOutputOnlyToken = nil
        routeText = "Unknown"
        iceStateText = "Inactive"
        remoteDisplayName = "Mac mini"
        invitationExpiresAt = nil
        statistics = nil
    }

    // MARK: - Runtime audio proof

    private func macHostedCallChallengeChanged(
        _ challenge: WebRTCMacHostedCallChallenge?
    ) {
        if currentMacHostedCallChallenge != challenge {
            retireMacHostedCallChallengeSendAttempt()
        }
        invalidateMacHostedCallEvidence(notifyLifecycle: false)
        currentMacHostedCallChallenge = challenge
        sendMacHostedCallChallengeIfPossible()
    }

    /// Opens the challenge lane only after the ordered answer was successfully forwarded. Merely
    /// installing the local SDP capability is insufficient: a locally successful data-channel send
    /// can otherwise overtake signaling and be discarded by a host that has not applied the answer.
    private func macHostedCallAnswerWasForwardedIfCurrent(
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID,
        sourceNegotiationGeneration: UUID
    ) {
        guard sourceGeneration == sessionGeneration,
              sourceNegotiationGeneration
                == macHostedCallNegotiationGeneration,
              peer === sourcePeer else {
            return
        }
        macHostedCallAnswerForwardedBinding =
            MacHostedCallAnswerForwardedBinding(
                peerIdentity: ObjectIdentifier(sourcePeer),
                sessionGeneration: sourceGeneration,
                negotiationGeneration:
                    sourceNegotiationGeneration
            )
        sendMacHostedCallChallengeIfPossible()
    }

    /// Sends only under the exact current peer/session/transport/negotiation generation whose
    /// answer has already crossed signaling. The peer independently rechecks native health and the
    /// bidirectional SDP capability before touching the wire.
    private func sendMacHostedCallChallengeIfPossible() {
        guard let challenge = currentMacHostedCallChallenge,
              challenge.isValid,
              let sourcePeer = peer,
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady,
              !recoveryProofRequired else {
            return
        }
        let sourceGeneration = sessionGeneration
        let sourceTransportGeneration =
            transportAuthorizationGeneration
        let sourceNegotiationGeneration =
            macHostedCallNegotiationGeneration
        let answerBinding = MacHostedCallAnswerForwardedBinding(
            peerIdentity: ObjectIdentifier(sourcePeer),
            sessionGeneration: sourceGeneration,
            negotiationGeneration: sourceNegotiationGeneration
        )
        guard macHostedCallAnswerForwardedBinding == answerBinding else {
            return
        }
        let binding = MacHostedCallChallengeSendBinding(
            peerIdentity: ObjectIdentifier(sourcePeer),
            sessionGeneration: sourceGeneration,
            transportAuthorizationGeneration:
                sourceTransportGeneration,
            negotiationGeneration: sourceNegotiationGeneration,
            challenge: challenge
        )
        guard successfullySentMacHostedCallChallengeBinding
                != binding else {
            return
        }
        if macHostedCallChallengeSendTask != nil {
            if macHostedCallChallengeSendBinding == binding {
                // Coalesce concurrent lifecycle/health triggers into this bounded two-attempt
                // operation. Later explicit healthy events may redrive after it has completed.
                return
            }
            retireMacHostedCallChallengeSendAttempt()
        }

        let attemptID = UUID()
        macHostedCallChallengeSendAttemptID = attemptID
        macHostedCallChallengeSendBinding = binding
        macHostedCallChallengeSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var didSend = false
            defer {
                if macHostedCallChallengeSendAttemptID == attemptID {
                    macHostedCallChallengeSendTask = nil
                    macHostedCallChallengeSendAttemptID = nil
                    macHostedCallChallengeSendBinding = nil
                    if didSend {
                        successfullySentMacHostedCallChallengeBinding = binding
                    }
                }
            }

            for attemptOrdinal in 0...1 {
                guard macHostedCallChallengeSendIsCurrent(
                    attemptID: attemptID,
                    binding: binding,
                    answerBinding: answerBinding,
                    sourcePeer: sourcePeer
                ) else {
                    return
                }

                do {
                    #if DEBUG
                    if let debugMacHostedCallChallengeSender {
                        try await debugMacHostedCallChallengeSender(
                            sourcePeer,
                            challenge
                        )
                    } else {
                        try await sourcePeer
                            .requestMacHostedCallEvidenceIfTransportHealthy(
                                challenge: challenge
                            )
                    }
                    #else
                    try await sourcePeer
                        .requestMacHostedCallEvidenceIfTransportHealthy(
                            challenge: challenge
                        )
                    #endif
                    guard macHostedCallChallengeSendIsCurrent(
                        attemptID: attemptID,
                        binding: binding,
                        answerBinding: answerBinding,
                        sourcePeer: sourcePeer
                    ) else {
                        return
                    }
                    didSend = true
                    return
                } catch {
                    guard attemptOrdinal == 0,
                          macHostedCallChallengeSendIsCurrent(
                            attemptID: attemptID,
                            binding: binding,
                            answerBinding: answerBinding,
                            sourcePeer: sourcePeer
                          ),
                          await waitForMacHostedCallChallengeAutomaticRetry(),
                          macHostedCallChallengeSendIsCurrent(
                            attemptID: attemptID,
                            binding: binding,
                            answerBinding: answerBinding,
                            sourcePeer: sourcePeer
                          ) else {
                        return
                    }
                }
            }
        }
    }

    private func macHostedCallChallengeSendIsCurrent(
        attemptID: UUID,
        binding: MacHostedCallChallengeSendBinding,
        answerBinding: MacHostedCallAnswerForwardedBinding,
        sourcePeer: WebRTCPeer
    ) -> Bool {
        macHostedCallChallengeSendAttemptID == attemptID
            && macHostedCallChallengeSendBinding == binding
            && binding.sessionGeneration == sessionGeneration
            && binding.transportAuthorizationGeneration
                == transportAuthorizationGeneration
            && binding.negotiationGeneration
                == macHostedCallNegotiationGeneration
            && macHostedCallAnswerForwardedBinding == answerBinding
            && peer === sourcePeer
            && binding.peerIdentity == ObjectIdentifier(sourcePeer)
            && currentMacHostedCallChallenge == binding.challenge
            && binding.challenge.isValid
            && successfullySentMacHostedCallChallengeBinding != binding
            && isPeerConnected
            && iceIsConnected
            && isControlChannelReady
            && !recoveryProofRequired
    }

    private func waitForMacHostedCallChallengeAutomaticRetry() async -> Bool {
        #if DEBUG
        if let debugMacHostedCallChallengeAutomaticRetryWaiter {
            await debugMacHostedCallChallengeAutomaticRetryWaiter()
            return !Task.isCancelled
        }
        #endif
        do {
            try await Task.sleep(
                for: Self.macHostedCallChallengeAutomaticRetryDelay
            )
            return true
        } catch {
            return false
        }
    }

    /// Retires both a forwarded-answer proof and every send derived from it. Rotating the
    /// negotiation generation prevents a delayed answer callback from reopening a newer transport.
    private func beginMacHostedCallNegotiationBoundary() {
        macHostedCallNegotiationGeneration = UUID()
        macHostedCallAnswerForwardedBinding = nil
        retireMacHostedCallChallengeSendAttempt()
    }

    private func retireMacHostedCallChallengeSendAttempt() {
        macHostedCallChallengeSendTask?.cancel()
        macHostedCallChallengeSendTask = nil
        macHostedCallChallengeSendAttemptID = nil
        macHostedCallChallengeSendBinding = nil
        successfullySentMacHostedCallChallengeBinding = nil
    }

    /// Owns the short evidence lease for one exact peer/session/sequence. One-second host
    /// heartbeats renew it; silence for 2.5 seconds closes microphone eligibility.
    private func handleMacHostedCallEvidence(
        _ evidence: WebRTCMacHostedCallEvidence?,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID
    ) {
        guard sourceGeneration == sessionGeneration,
              peer === sourcePeer else {
            return
        }
        guard let evidence else {
            invalidateMacHostedCallEvidence()
            return
        }
        guard let challenge = currentMacHostedCallChallenge,
              evidence.isValid,
              evidence.challengeSequence == challenge.sequence,
              evidence.challengeNonce == challenge.nonce,
              evidence.callEpochNonce == challenge.callEpochNonce,
              currentMacHostedCallEvidence.map({
                  evidence.sequence > $0.sequence
              }) ?? true else {
            invalidateMacHostedCallEvidence()
            return
        }

        macHostedCallEvidenceLeaseTask?.cancel()
        macHostedCallEvidenceLeaseTask = nil
        currentMacHostedCallEvidence = evidence
        audioLifecycle.macHostedCallEvidenceChanged(evidence)

        guard evidence.state == .active else { return }
        let expectedSequence = evidence.sequence
        let expectedChallenge = challenge
        let expectedTransportGeneration =
            transportAuthorizationGeneration
        macHostedCallEvidenceLeaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2_500))
            } catch {
                return
            }
            guard let self,
                  sourceGeneration == sessionGeneration,
                  expectedTransportGeneration
                    == transportAuthorizationGeneration,
                  peer === sourcePeer,
                  currentMacHostedCallChallenge
                    == expectedChallenge,
                  currentMacHostedCallEvidence?.sequence
                    == expectedSequence,
                  currentMacHostedCallEvidence?.state == .active else {
                return
            }
            invalidateMacHostedCallEvidence()
        }
    }

    private func invalidateMacHostedCallEvidence(
        notifyLifecycle: Bool = true
    ) {
        macHostedCallEvidenceLeaseTask?.cancel()
        macHostedCallEvidenceLeaseTask = nil
        guard currentMacHostedCallEvidence != nil else { return }
        currentMacHostedCallEvidence = nil
        if notifyLifecycle {
            audioLifecycle.macHostedCallEvidenceChanged(nil)
        }
    }

    private func microphoneCallDispositionChanged(
        _ disposition: WorldwideMicrophoneCallDisposition
    ) {
        let previousDisposition = currentMicrophoneCallDisposition
        let isActive = disposition == .blocked
        if microphoneIsBlockedByCall != isActive {
            invalidateRawMicrophoneOracle()
        }
        if disposition == .inactive {
            retireIOSHostedCallPlayoutAttempt()
        }
        let dispositionChanged = previousDisposition != disposition
        currentMicrophoneCallDisposition = disposition
        microphoneIsBlockedByCall = isActive
        microphoneAwaitsPostCallRecovery =
            disposition == .inactive
                && previousDisposition == .blocked
        guard dispositionChanged
                || disposition == .macHosted else {
            return
        }
        guard microphoneIntentEnabled else { return }
        switch disposition {
        case .blocked:
            suspendIPhoneMicrophone(
                stateText: "Muted — iPhone call active",
                preserveIntent: true,
                reprovePlayout: false,
                performNativeTeardown: false
            )
        case .inactive:
            if microphoneAwaitsPostCallRecovery {
                microphoneStateText = "Paused — restoring microphone"
            }
        case .macHosted:
            retireIOSHostedCallPlayoutAttempt()
            microphoneAwaitsPostCallRecovery = false
            microphoneStateText = "Paused — restoring microphone"
            continueIPhoneMicrophoneEnablementIfPossible()
        }
    }

    private func postCallAudioRecoveryCompleted() {
        guard microphoneAwaitsPostCallRecovery,
              !microphoneIsBlockedByCall else {
            return
        }
        microphoneAwaitsPostCallRecovery = false
        guard microphoneIntentEnabled else { return }
        microphoneStateText = "Paused — restoring microphone"
        continueIPhoneMicrophoneEnablementIfPossible()
    }

    private func invalidateAudioPolicyProof(requiresFreshRecovery: Bool) {
        // Rotate first so every suspended read/proof immediately loses ownership, including the
        // difficult case where an interruption or call starts and ends before a non-cooperative
        // await resumes.
        if requiresFreshRecovery {
            audioPolicyRequiresFreshRecovery = true
        }
        audioPolicyGeneration = UUID()
        verifiedAudioPolicyGeneration = nil
        audioPlayoutOracle = nil
        ordinaryPlayoutLivenessTracker.reset()
        audioPlayoutProofTask?.cancel()
        audioPlayoutProofTask = nil
        retireIOSHostedCallPlayoutAttempt()
        retireIOSPlayoutRecoveryAttempt()
    }

    /// A signaling/ICE success is not proof that RemoteIO is receiving healthy media PCM. Its
    /// callback buffer is still before iOS's final system mixer, route processing, DAC, and speaker.
    /// Recovery owns an immutable pre-request regression baseline; its first post-authorization
    /// snapshot establishes the new cumulative-counter floor.
    @discardableResult
    private func beginIOSPlayoutProof(
        requestRecovery: Bool,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone? = nil,
        categoryProofClaim:
            WorldwideAudioCategoryProofClaim? = nil
    ) -> Task<Void, Never>? {
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall else {
            return nil
        }
        retireIOSPlayoutRecoveryAttempt()
        audioPlayoutProofTask?.cancel()
        audioPlayoutProofTask = nil
        guard let proofPeer = peer else {
            if let categoryProofClaim {
                // The claimed refresh is the only completion path for a category notification
                // blocked by a same-target tombstone. A peer disappearing before the bounded
                // proof can start is therefore a terminal closed result, not a pending operation
                // that waits forever for a second AVAudioSession notification.
                audioLifecycle.updateRuntimePlayout(
                    isReady: false,
                    failureMessage:
                        "The iPhone 48 kHz stereo render path did not start.",
                    diagnostic:
                        "The current peer retired before the claimed category proof could start.",
                    categoryProofClaim: categoryProofClaim
                )
            }
            return nil
        }

        let requiresRecovery = requestRecovery || audioPolicyRequiresFreshRecovery
        let proofAudioPolicyGeneration = audioPolicyGeneration
        verifiedAudioPolicyGeneration = nil
        audioPlayoutOracle = nil
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            categoryProofClaim: categoryProofClaim
        )
        let attempt = IOSPlayoutProofAttempt(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: proofAudioPolicyGeneration,
            expectedPeer: proofPeer,
            postCallRecoveryMilestone:
                requiresRecovery
                    ? postCallRecoveryMilestone
                    : nil,
            categoryProofClaim: categoryProofClaim,
            stage: requiresRecovery ? .awaitingRecoveryBaseline : .awaitingInitialFloor
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

            if requiresRecovery {
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
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall else { return }
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
                generation: attempt.sessionGeneration,
                policyGeneration: attempt.audioPolicyGeneration,
                inboundAudio: statistics?.inboundAudio
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
        generation: UUID,
        statistics: WebRTCStatisticsSnapshot
    ) async {
        let expectedPolicyGeneration = audioPolicyGeneration
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall,
              generation == sessionGeneration,
              peer === sourcePeer,
              verifiedAudioPolicyGeneration == expectedPolicyGeneration else { return }
        guard let diagnostics = await readIOSPlayoutDiagnostics(from: sourcePeer) else {
            return
        }
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall,
              generation == sessionGeneration,
              peer === sourcePeer,
              audioPolicyGeneration == expectedPolicyGeneration,
              verifiedAudioPolicyGeneration == expectedPolicyGeneration else { return }
        guard let oracle = publishIOSPlayoutOracle(
            diagnostics,
            from: sourcePeer,
            generation: generation,
            policyGeneration: expectedPolicyGeneration,
            inboundAudio: statistics.inboundAudio
        ) else { return }
        evaluateOrdinaryPlayoutLiveness(
            oracle,
            from: sourcePeer,
            generation: generation,
            policyGeneration: expectedPolicyGeneration,
            collectedAt: statistics.collectedAt
        )
    }

    @discardableResult
    private func publishIOSPlayoutOracle(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        from sourcePeer: WebRTCPeer,
        generation: UUID,
        policyGeneration: UUID,
        inboundAudio: WebRTCAudioStatistics?
    ) -> WorldwideAudioPlayoutOracleSnapshot? {
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall,
              generation == sessionGeneration,
              peer === sourcePeer,
              policyGeneration == audioPolicyGeneration,
              verifiedAudioPolicyGeneration == policyGeneration else { return nil }
        if let current = audioPlayoutOracle,
           current.sessionGeneration == generation,
           current.audioPolicyGeneration == policyGeneration {
            guard diagnostics.playoutCallbackCount >= current.callbackCount,
                  diagnostics.playoutFrameCount >= current.frameCount,
                  diagnostics.playoutFailureCount >= current.failureCount else { return nil }
        }
        let oracle = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: generation,
            audioPolicyGeneration: policyGeneration,
            diagnostics: diagnostics,
            inboundAudio: inboundAudio
        )
        audioPlayoutOracle = oracle
        return oracle
    }

    private func evaluateOrdinaryPlayoutLiveness(
        _ oracle: WorldwideAudioPlayoutOracleSnapshot,
        from sourcePeer: WebRTCPeer,
        generation: UUID,
        policyGeneration: UUID,
        collectedAt: Date
    ) {
        let result = ordinaryPlayoutLivenessTracker.observe(
            sessionGeneration: generation,
            audioPolicyGeneration: policyGeneration,
            peerIdentity: ObjectIdentifier(sourcePeer),
            collectedAt: collectedAt,
            oracle: oracle
        )
        switch result {
        case .waiting:
            return
        case .healthy:
            ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = nil
            ordinaryPlayoutAutomaticFailureWasPublished = false
        case .recover(let failure):
            recoverFromStalledOrdinaryPlayout(
                failure,
                generation: generation
            )
        }
    }

    private func recoverFromStalledOrdinaryPlayout(
        _ failure: IOSOrdinaryPlayoutLivenessFailure,
        generation: UUID
    ) {
        guard generation == sessionGeneration else { return }
        if ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration
            == generation {
            guard !ordinaryPlayoutAutomaticFailureWasPublished else {
                return
            }
            ordinaryPlayoutAutomaticFailureWasPublished = true
            let diagnostic: String
            switch failure {
            case .callbacksFrozen:
                diagnostic =
                    "RemoteIO render callbacks stayed frozen after one automatic recovery."
            case .inboundEnergyWithoutPCM:
                diagnostic =
                    "WebRTC received advancing Mac audio energy, but RemoteIO decoded PCM stayed silent after one automatic recovery."
            }
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                failureMessage:
                    "The iPhone received audio but could not render it. Tap Retry Audio.",
                diagnostic: diagnostic
            )
            return
        }

        guard audioLifecycle.requestAutomaticRuntimeAudioRecovery() else {
            return
        }
        ordinaryPlayoutAutomaticRecoveryConsumedSessionGeneration = generation
        ordinaryPlayoutAutomaticFailureWasPublished = false
        ordinaryPlayoutLivenessTracker.reset()
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

    private static let iosHostedCallPlayoutSetupTimeout: Duration = .seconds(2)
    private static let iosHostedCallPlayoutEvidenceTimeout: Duration = .milliseconds(3_500)
    private static let iosHostedCallPlayoutSteadyTimeout: Duration = .milliseconds(3_500)
    private static let iosHostedCallPlayoutMaximumRecoveryRequestCount = 4
    private static let iosHostedCallPlayoutRecoveryRetryPollInterval = 4

    private var hasOwnedIOSHostedCallPlayoutPolicy: Bool {
        iosPendingStartupConnectedCallPlayout != nil
            || iosHostedCallPlayoutAttempt != nil
            || iosHostedCallPlayoutAuthorization != nil
    }

    private var ordinaryIOSPlayoutProofIsSuppressedByHostedCall: Bool {
        hasOwnedIOSHostedCallPlayoutPolicy
            || (microphoneIsBlockedByCall && audioPolicyRequiresFreshRecovery)
    }

    private func handleIOSHostedCallPeerReplacement(
        from oldPeer: WebRTCPeer?,
        to newPeer: WebRTCPeer?
    ) {
        if let pending = iosPendingStartupConnectedCallPlayout,
           oldPeer == nil,
           let newPeer,
           pending.expectedPeer == nil,
           iosPendingStartupConnectedCallPlayoutIsOwned(pending),
           pending.bindFirstPeer(newPeer) {
            return
        }
        retireIOSHostedCallPlayoutAttempt()
    }

    private func iosPendingStartupConnectedCallPlayoutIsOwned(
        _ pending: IOSPendingStartupConnectedCallPlayout
    ) -> Bool {
        guard
            iosPendingStartupConnectedCallPlayout === pending,
            iosHostedCallPlayoutAuthorization === pending.authorization,
            iosHostedCallPlayoutScopeID == pending.scopeID,
            iosHostedCallPlayoutPolicyID == pending.policyID,
            pending.policyID == pending.authorization.policyID,
            pending.authorization.origin == .startupConnectedCall,
            pending.authorizationIdentity
                == ObjectIdentifier(pending.authorization),
            pending.authorization.isValid,
            pending.authorization.isRecoveryPending,
            pending.sessionGeneration == sessionGeneration,
            pending.audioPolicyGeneration == audioPolicyGeneration
        else {
            return false
        }

        if let expectedPeer = pending.expectedPeer {
            guard pending.expectedPeerIdentity == ObjectIdentifier(expectedPeer),
                  peer === expectedPeer else {
                return false
            }
        } else if peer != nil {
            return false
        }
        return true
    }

    @discardableResult
    private func beginIOSHostedCallPlayoutProof(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) -> Task<Void, Never>? {
        if iosHostedCallPlayoutAuthorization === authorization {
            if let pending = iosPendingStartupConnectedCallPlayout,
               pending.authorization === authorization,
               pending.policyID == authorization.policyID,
               iosPendingStartupConnectedCallPlayoutIsOwned(pending) {
                return nil
            }
            if let attempt = iosHostedCallPlayoutAttempt,
               attempt.authorization === authorization,
               attempt.policyID == authorization.policyID,
               iosHostedCallPlayoutAttemptIsOwned(attempt) {
                return iosHostedCallPlayoutProofTask
            }
            audioLifecycle.failHostedCallRuntimePlayout(
                policyID: authorization.policyID,
                authorization: authorization,
                failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
                diagnostic: "The hosted-call authorization was redelivered without its exact owned startup or proof window."
            )
            retireIOSHostedCallPlayoutAttempt()
            return nil
        }

        guard let scopeID = audioLifecycle.hostedCallScopeID(
            for: authorization
        ) else {
            authorization.revoke()
            return nil
        }

        retireIOSHostedCallPlayoutAttempt()
        guard authorization.isValid,
              authorization.isRecoveryPending else {
            audioLifecycle.failHostedCallRuntimePlayout(
                policyID: authorization.policyID,
                authorization: authorization,
                failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
                diagnostic: "The exact hosted-call authorization was invalid or already consumed when delivered."
            )
            return nil
        }

        switch authorization.origin {
        case .startupConnectedCall:
            let pending = IOSPendingStartupConnectedCallPlayout(
                scopeID: scopeID,
                authorization: authorization,
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration
            )
            iosPendingStartupConnectedCallPlayout = pending
            iosHostedCallPlayoutAuthorization = authorization
            iosHostedCallPlayoutScopeID = scopeID
            iosHostedCallPlayoutPolicyID = authorization.policyID
            if let peer {
                guard pending.bindFirstPeer(peer) else {
                    audioLifecycle.failHostedCallRuntimePlayout(
                        policyID: authorization.policyID,
                        authorization: authorization,
                        failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
                        diagnostic: "The startup-connected-call authorization could not bind its first WebRTC peer."
                    )
                    retireIOSHostedCallPlayoutAttempt()
                    return nil
                }
            }
            return nil

        case .interruption:
            guard let proofPeer = peer else {
                audioLifecycle.failHostedCallRuntimePlayout(
                    policyID: authorization.policyID,
                    authorization: authorization,
                    failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
                    diagnostic: "The interruption-origin hosted-call policy arrived without a current WebRTC peer."
                )
                authorization.revoke()
                return nil
            }
            let attempt = IOSHostedCallPlayoutProofAttempt(
                scopeID: scopeID,
                authorization: authorization,
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                expectedPeer: proofPeer,
                stage: .awaitingNativeQuiescence
            )
            installIOSHostedCallPlayoutAttempt(attempt)
            return nil
        }
    }

    private func installIOSHostedCallPlayoutAttempt(
        _ attempt: IOSHostedCallPlayoutProofAttempt
    ) {
        iosPendingStartupConnectedCallPlayout = nil
        iosHostedCallPlayoutAttempt = attempt
        iosHostedCallPlayoutAuthorization = attempt.authorization
        iosHostedCallPlayoutProofAttemptID = attempt.proofAttemptID
        iosHostedCallPlayoutCounterWindowID = attempt.counterWindowID
        iosHostedCallPlayoutScopeID = attempt.scopeID
        iosHostedCallPlayoutPolicyID = attempt.policyID
    }

    private func resumeIOSHostedCallPlayoutProof(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) {
        guard let attempt = iosHostedCallPlayoutAttempt,
              attempt.authorization === authorization,
              attempt.origin == .interruption,
              attempt.stage == .awaitingNativeQuiescence,
              attempt.authorization.isValid,
              attempt.authorization.isRecoveryPending,
              iosHostedCallPlayoutAttemptIsOwned(attempt),
              iosHostedCallPlayoutProofTask == nil else {
            return
        }

        armIOSHostedCallPlayoutTimeout(.setup, for: attempt)
        _ = startIOSHostedCallPlayoutProofTask(for: attempt)
    }

    @discardableResult
    private func startIOSHostedCallPlayoutProofTask(
        for attempt: IOSHostedCallPlayoutProofAttempt
    ) -> Task<Void, Never> {
        let proofTask = Task { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            while true {
                guard iosHostedCallPlayoutAttemptIsOwned(attempt),
                      attempt.stage == .awaitingNativeQuiescence
                        || attempt.stage == .awaitingNativeRecovery else { return }
                attempt.pollOrdinal += 1
                if let diagnostics = await ownedIOSHostedCallPlayoutDiagnostics(
                    for: attempt,
                    from: attempt.expectedPeer
                ) {
                    guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return }
                    if await evaluateIOSHostedCallPlayoutDiagnostics(
                        diagnostics,
                        statistics: statistics,
                        for: attempt,
                        source: .polling
                    ) {
                        return
                    }
                }
                guard await waitForIOSHostedCallPlayoutPoll(attempt) else { return }
            }
        }
        iosHostedCallPlayoutProofTask = proofTask
        return proofTask
    }

    private func armIOSHostedCallPlayoutTimeout(
        _ phase: IOSHostedCallPlayoutTimeoutPhase,
        for attempt: IOSHostedCallPlayoutProofAttempt
    ) {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return }
        let timeoutID = UUID()
        attempt.timeoutPhase = phase
        attempt.timeoutID = timeoutID
        iosHostedCallPlayoutProofTimeoutTask?.cancel()
        iosHostedCallPlayoutProofTimeoutTask = Task { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            guard await waitForIOSHostedCallPlayoutTimeout(
                attempt,
                phase: phase,
                timeoutID: timeoutID
            ) else { return }
            failIOSHostedCallPlayoutProofTimeout(
                attempt,
                phase: phase,
                timeoutID: timeoutID
            )
        }
    }

    private func waitForIOSHostedCallPlayoutPoll(
        _ attempt: IOSHostedCallPlayoutProofAttempt
    ) async -> Bool {
        guard !Task.isCancelled, iosHostedCallPlayoutAttemptIsOwned(attempt) else {
            return false
        }
        #if DEBUG
        if let debugIOSHostedCallPlayoutPollWaiter {
            await debugIOSHostedCallPlayoutPollWaiter()
        } else {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        #else
        do {
            try await Task.sleep(for: .milliseconds(50))
        } catch {
            return false
        }
        #endif
        return !Task.isCancelled && iosHostedCallPlayoutAttemptIsOwned(attempt)
    }

    private func waitForIOSHostedCallPlayoutTimeout(
        _ attempt: IOSHostedCallPlayoutProofAttempt,
        phase: IOSHostedCallPlayoutTimeoutPhase,
        timeoutID: UUID
    ) async -> Bool {
        guard !Task.isCancelled,
              iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.timeoutPhase == phase,
              attempt.timeoutID == timeoutID else {
            return false
        }

        #if DEBUG
        let phaseWaiter: (@MainActor () async -> Void)?
        switch phase {
        case .setup:
            phaseWaiter = debugIOSHostedCallPlayoutSetupTimeoutWaiter
        case .evidence:
            phaseWaiter = debugIOSHostedCallPlayoutEvidenceTimeoutWaiter
        case .steady:
            phaseWaiter = debugIOSHostedCallPlayoutSteadyTimeoutWaiter
        }
        if let phaseWaiter {
            await phaseWaiter()
        } else {
            do {
                try await Task.sleep(
                    for: Self.iOSHostedCallPlayoutTimeoutDuration(for: phase)
                )
            } catch {
                return false
            }
        }
        #else
        do {
            try await Task.sleep(
                for: Self.iOSHostedCallPlayoutTimeoutDuration(for: phase)
            )
        } catch {
            return false
        }
        #endif
        return !Task.isCancelled
            && iosHostedCallPlayoutAttemptIsOwned(attempt)
            && attempt.timeoutPhase == phase
            && attempt.timeoutID == timeoutID
    }

    private func refreshIOSHostedCallPlayoutProof(
        from sourcePeer: WebRTCPeer,
        generation: UUID,
        statistics snapshot: WebRTCStatisticsSnapshot
    ) async {
        guard let attempt = iosHostedCallPlayoutAttempt,
              generation == attempt.sessionGeneration,
              sourcePeer === attempt.expectedPeer,
              iosHostedCallPlayoutAttemptIsOwned(attempt) else { return }
        guard let diagnostics = await ownedIOSHostedCallPlayoutDiagnostics(
            for: attempt,
            from: sourcePeer
        ) else { return }
        guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return }
        _ = await evaluateIOSHostedCallPlayoutDiagnostics(
            diagnostics,
            statistics: snapshot,
            for: attempt,
            source: .statistics
        )
    }

    private func ownedIOSHostedCallPlayoutDiagnostics(
        for attempt: IOSHostedCallPlayoutProofAttempt,
        from proofPeer: WebRTCPeer
    ) async -> WebRTCIOSPlayoutDiagnostics? {
        guard !Task.isCancelled,
              iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.expectedPeer === proofPeer else {
            return nil
        }
        let expectedStage = attempt.stage
        let readOrdinal = attempt.nextDiagnosticReadOrdinal
        attempt.nextDiagnosticReadOrdinal &+= 1
        let diagnostics = await readIOSPlayoutDiagnostics(from: proofPeer)
        guard !Task.isCancelled,
              iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.expectedPeer === proofPeer,
              attempt.stage == expectedStage,
              readOrdinal > attempt.latestAcceptedDiagnosticReadOrdinal else {
            return nil
        }
        attempt.latestAcceptedDiagnosticReadOrdinal = readOrdinal
        return diagnostics
    }

    private func activatePendingIOSStartupConnectedCallPlayoutIfPossible() async {
        guard let pending = iosPendingStartupConnectedCallPlayout else {
            return
        }
        guard iosPendingStartupConnectedCallPlayoutIsOwned(pending),
              !recoveryProofRequired,
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady,
              let proofPeer = pending.expectedPeer,
              pending.expectedPeerIdentity == ObjectIdentifier(proofPeer),
              peer === proofPeer,
              audioLifecycle.hostedCallScopeID(
                for: pending.authorization
              ) == pending.scopeID else {
            failPendingIOSStartupConnectedCallPlayout(
                pending,
                diagnostic: "The startup-connected-call policy reached the healthy transport boundary without its exact peer, generation, or lifecycle scope."
            )
            return
        }

        let armed = await armIOSStartupConnectedCallPlayout(
            on: proofPeer,
            authorization: pending.authorization
        )

        guard
            iosPendingStartupConnectedCallPlayout === pending,
            iosHostedCallPlayoutAuthorization === pending.authorization,
            iosHostedCallPlayoutScopeID == pending.scopeID,
            iosHostedCallPlayoutPolicyID == pending.policyID,
            pending.sessionGeneration == sessionGeneration,
            pending.audioPolicyGeneration == audioPolicyGeneration,
            pending.expectedPeer === proofPeer,
            pending.expectedPeerIdentity == ObjectIdentifier(proofPeer),
            peer === proofPeer,
            audioLifecycle.hostedCallScopeID(
                for: pending.authorization
            ) == pending.scopeID
        else {
            return
        }

        guard armed,
              pending.authorization.isValid,
              !pending.authorization.isRecoveryPending,
              pending.authorization.systemAudioGeneration != 0,
              pending.authorization.origin == .startupConnectedCall else {
            failPendingIOSStartupConnectedCallPlayout(
                pending,
                diagnostic: "Native audio rejected or failed to consume the exact quiescent startup-connected-call arm."
            )
            return
        }

        let attempt = IOSHostedCallPlayoutProofAttempt(
            scopeID: pending.scopeID,
            authorization: pending.authorization,
            sessionGeneration: pending.sessionGeneration,
            audioPolicyGeneration: pending.audioPolicyGeneration,
            expectedPeer: proofPeer,
            stage: .awaitingNativeRecovery
        )
        installIOSHostedCallPlayoutAttempt(attempt)

        guard audioLifecycle.activateArmedStartupConnectedCallPlayout(
            scopeID: attempt.scopeID,
            policyID: attempt.policyID,
            authorization: attempt.authorization
        ), iosHostedCallPlayoutAttemptIsOwned(attempt) else {
            _ = failIOSHostedCallPlayoutProof(
                attempt,
                diagnostic: "The app-owned manual WebRTC gate could not open under the exact natively armed startup policy."
            )
            return
        }

        armIOSHostedCallPlayoutTimeout(.setup, for: attempt)
        _ = startIOSHostedCallPlayoutProofTask(for: attempt)
    }

    private func failPendingIOSStartupConnectedCallPlayout(
        _ pending: IOSPendingStartupConnectedCallPlayout,
        diagnostic: String
    ) {
        guard iosPendingStartupConnectedCallPlayout === pending else {
            return
        }
        audioLifecycle.failHostedCallRuntimePlayout(
            policyID: pending.policyID,
            authorization: pending.authorization,
            failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
            diagnostic: diagnostic
        )
        retireIOSHostedCallPlayoutAttempt()
    }

    private func armIOSStartupConnectedCallPlayout(
        on proofPeer: WebRTCPeer,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) async -> Bool {
        return await proofPeer.armIOSStartupConnectedCallPlayout(
            authorization: authorization
        )
    }

    private func requestIOSHostedCallPlayoutRecovery(
        for attempt: IOSHostedCallPlayoutProofAttempt
    ) async -> Bool {
        guard !Task.isCancelled,
              iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.stage == .awaitingNativeRecovery,
              attempt.origin == .interruption,
              attempt.authorization.isValid,
              attempt.authorization.isRecoveryPending,
              attempt.recoveryRequestCount < Self.iosHostedCallPlayoutMaximumRecoveryRequestCount,
              peer === attempt.expectedPeer else { return false }
        #if DEBUG
        if let debugIOSHostedCallPlayoutRequestPreflightWaiter {
            await debugIOSHostedCallPlayoutRequestPreflightWaiter()
            guard !Task.isCancelled,
                  iosHostedCallPlayoutAttemptIsOwned(attempt),
                  attempt.stage == .awaitingNativeRecovery,
                  attempt.origin == .interruption,
                  attempt.authorization.isValid,
                  attempt.authorization.isRecoveryPending,
                  attempt.recoveryRequestCount < Self.iosHostedCallPlayoutMaximumRecoveryRequestCount,
                  peer === attempt.expectedPeer else { return false }
        }
        #endif
        attempt.recoveryRequestCount += 1
        attempt.nextRecoveryRequestPollOrdinal =
            attempt.pollOrdinal + Self.iosHostedCallPlayoutRecoveryRetryPollInterval
        #if DEBUG
        if let debugIOSHostedCallPlayoutRecoveryRequester {
            debugIOSHostedCallPlayoutRecoveryRequester(
                attempt.expectedPeer,
                attempt.authorization
            )
        } else {
            await attempt.expectedPeer.requestIOSHostedCallPlayoutRecovery(
                authorization: attempt.authorization
            )
        }
        #else
        await attempt.expectedPeer.requestIOSHostedCallPlayoutRecovery(
            authorization: attempt.authorization
        )
        #endif
        return !Task.isCancelled
            && iosHostedCallPlayoutAttemptIsOwned(attempt)
            && attempt.stage == .awaitingNativeRecovery
            && attempt.origin == .interruption
    }

    @discardableResult
    private func evaluateIOSHostedCallPlayoutDiagnostics(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        statistics snapshot: WebRTCStatisticsSnapshot?,
        for attempt: IOSHostedCallPlayoutProofAttempt,
        source: IOSHostedCallPlayoutProofSource
    ) async -> Bool {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return false }

        func fail(_ context: String) -> Bool {
            failIOSHostedCallPlayoutProof(
                attempt,
                diagnostic: Self.iOSHostedCallPlayoutDiagnostic(
                    context,
                    diagnostics: diagnostics,
                    attempt: attempt
                )
            )
        }

        guard attempt.authorization.isValid else {
            return fail("The exact hosted-call authorization was invalidated before proof completed.")
        }
        if let last = attempt.lastCallbackCount, diagnostics.playoutCallbackCount < last {
            return fail("Hosted-call callback count regressed from \(last) to \(diagnostics.playoutCallbackCount).")
        }
        if let last = attempt.lastFrameCount, diagnostics.playoutFrameCount < last {
            return fail("Hosted-call frame count regressed from \(last) to \(diagnostics.playoutFrameCount).")
        }
        if let last = attempt.lastPCMNonzeroSampleCount,
           diagnostics.playoutPCMNonzeroSampleCount < last {
            return fail("Hosted-call nonzero PCM count regressed from \(last) to \(diagnostics.playoutPCMNonzeroSampleCount).")
        }
        if let last = attempt.lastPCMAbsoluteSampleSum,
           diagnostics.playoutPCMAbsoluteSampleSum < last {
            return fail("Hosted-call absolute PCM sum regressed from \(last) to \(diagnostics.playoutPCMAbsoluteSampleSum).")
        }
        if let last = attempt.lastFailureCount, diagnostics.playoutFailureCount < last {
            return fail("Hosted-call failure count regressed from \(last) to \(diagnostics.playoutFailureCount).")
        }
        if let last = attempt.lastUnexpectedRecordingRequestCount,
           diagnostics.unexpectedRecordingRequestCount < last {
            return fail("Hosted-call recording-request count regressed from \(last) to \(diagnostics.unexpectedRecordingRequestCount).")
        }

        if let floor = attempt.nativeCounterFloor {
            guard diagnostics.playoutFailureCount == floor.failureCount else {
                return fail("RemoteIO recorded a new hosted-call playout failure.")
            }
            guard diagnostics.unexpectedRecordingRequestCount == floor.unexpectedRecordingRequestCount else {
                return fail("RemoteIO received an unexpected recording request during hosted-call recovery.")
            }
        } else {
            attempt.nativeCounterFloor = IOSHostedCallPlayoutNativeCounterFloor(
                failureCount: diagnostics.playoutFailureCount,
                unexpectedRecordingRequestCount: diagnostics.unexpectedRecordingRequestCount
            )
        }

        attempt.lastCallbackCount = diagnostics.playoutCallbackCount
        attempt.lastFrameCount = diagnostics.playoutFrameCount
        attempt.lastPCMNonzeroSampleCount = diagnostics.playoutPCMNonzeroSampleCount
        attempt.lastPCMAbsoluteSampleSum = diagnostics.playoutPCMAbsoluteSampleSum
        attempt.lastFailureCount = diagnostics.playoutFailureCount
        attempt.lastUnexpectedRecordingRequestCount = diagnostics.unexpectedRecordingRequestCount

        switch attempt.stage {
        case .awaitingNativeQuiescence:
            guard attempt.origin == .interruption else {
                return fail("A startup-connected-call policy incorrectly entered interruption quiescence.")
            }
            guard attempt.authorization.isRecoveryPending else {
                return fail("The hosted-call recovery claim was consumed before native interruption quiescence was proved.")
            }
            guard Self.iOSHostedCallNativeQuiescenceIsVisible(diagnostics) else { return false }
            attempt.stage = .awaitingNativeRecovery
            guard source == .polling else { return false }
            _ = await requestIOSHostedCallPlayoutRecovery(for: attempt)
            guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return true }
            guard attempt.authorization.isValid else {
                return fail("Native hosted-call recovery invalidated its exact authorization.")
            }
            return false

        case .awaitingNativeRecovery:
            if attempt.authorization.isRecoveryPending {
                guard attempt.origin == .interruption else {
                    return fail("The synchronous startup-connected-call arm did not consume its exact native claim.")
                }
                guard source == .polling,
                      Self.iOSHostedCallNativeQuiescenceIsVisible(diagnostics),
                      attempt.recoveryRequestCount < Self.iosHostedCallPlayoutMaximumRecoveryRequestCount,
                      attempt.recoveryRequestCount == 0
                        || attempt.pollOrdinal >= attempt.nextRecoveryRequestPollOrdinal else {
                    return false
                }
                _ = await requestIOSHostedCallPlayoutRecovery(for: attempt)
                guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return true }
                guard attempt.authorization.isValid else {
                    return fail("Native hosted-call recovery rejected or invalidated its exact authorization.")
                }
                return false
            }

            let authorizationGeneration = attempt.authorization.systemAudioGeneration
            guard authorizationGeneration != 0 else {
                return fail("The hosted-call recovery claim completed without a system-audio generation.")
            }
            if diagnostics.systemAudioGeneration != 0,
               diagnostics.systemAudioGeneration != authorizationGeneration {
                return fail("The hosted-call system-audio generation no longer matches the exact authorization.")
            }
            if diagnostics.hostedCallAuthorizationGeneration != 0,
               diagnostics.hostedCallAuthorizationGeneration != authorizationGeneration {
                return fail("The native hosted-call authorization generation no longer matches the exact policy.")
            }
            guard Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                if Self.iOSHostedCallLifecycleFailureIsVisible(diagnostics)
                    || !diagnostics.hasOutputRoute {
                    return fail("Native hosted-call recovery completed without the required output-only topology.")
                }
                return false
            }
            return admitIOSHostedCallDecodedAudio(diagnostics: diagnostics, attempt: attempt)

        case .awaitingEvidenceFloor:
            guard Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                return fail("The installed hosted-call topology was lost before its proof floor was captured.")
            }
            guard source == .statistics else { return false }
            guard let runtimeGateAdmittedAt = attempt.runtimeGateAdmittedAt,
                  let snapshot,
                  snapshot.collectedAt >= runtimeGateAdmittedAt,
                  let inboundAudio = snapshot.inboundAudio,
                  Self.iOSHostedCallInboundAudioHasProofMetric(inboundAudio) else {
                return false
            }
            attempt.evidenceFloor = IOSHostedCallPlayoutEvidenceFloor(
                callbackCount: diagnostics.playoutCallbackCount,
                frameCount: diagnostics.playoutFrameCount,
                pcmNonzeroSampleCount: diagnostics.playoutPCMNonzeroSampleCount,
                pcmAbsoluteSampleSum: diagnostics.playoutPCMAbsoluteSampleSum,
                failureCount: diagnostics.playoutFailureCount,
                unexpectedRecordingRequestCount: diagnostics.unexpectedRecordingRequestCount,
                inboundAudio: inboundAudio,
                statisticsCollectedAt: snapshot.collectedAt
            )
            attempt.lastInboundAudioStatistics = inboundAudio
            attempt.lastStatisticsCollectedAt = snapshot.collectedAt
            attempt.stage = .awaitingFreshEvidence
            return false

        case .awaitingFreshEvidence:
            guard Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                return fail("The installed hosted-call topology changed during its proof window.")
            }
            guard source == .statistics else { return false }
            guard let floor = attempt.evidenceFloor else {
                return fail("The hosted-call proof window lost its exact counter floor.")
            }
            guard diagnostics.playoutFailureCount == floor.failureCount,
                  diagnostics.unexpectedRecordingRequestCount == floor.unexpectedRecordingRequestCount else {
                return fail("A playout failure or unexpected recording request changed during the hosted-call evidence window.")
            }

            let nativeEvidenceAdvanced =
                diagnostics.playoutCallbackCount > floor.callbackCount
                && diagnostics.playoutFrameCount > floor.frameCount
                && (
                    diagnostics.playoutPCMNonzeroSampleCount > floor.pcmNonzeroSampleCount
                    || diagnostics.playoutPCMAbsoluteSampleSum > floor.pcmAbsoluteSampleSum
                )
            guard let snapshot,
                  snapshot.collectedAt > floor.statisticsCollectedAt,
                  let inboundAudio = snapshot.inboundAudio,
                  Self.iOSHostedCallInboundAudioHasProofMetric(inboundAudio) else {
                return false
            }
            if let lastCollectedAt = attempt.lastStatisticsCollectedAt {
                if snapshot.collectedAt < lastCollectedAt {
                    return fail("Inbound WebRTC audio statistics regressed to an older proof sample.")
                }
                guard snapshot.collectedAt > lastCollectedAt else { return false }
            }
            if let previous = attempt.lastInboundAudioStatistics,
               Self.iOSHostedCallInboundAudioStatisticsRegressed(from: previous, to: inboundAudio) {
                return fail("Inbound WebRTC audio statistics regressed during the hosted-call proof window.")
            }
            attempt.lastInboundAudioStatistics = inboundAudio
            attempt.lastStatisticsCollectedAt = snapshot.collectedAt
            let inboundStatisticsAdvanced =
                Self.iOSHostedCallInboundAudioStatisticsAdvanced(
                    from: floor.inboundAudio,
                    to: inboundAudio
                )
            guard nativeEvidenceAdvanced,
                  inboundStatisticsAdvanced,
                  iosHostedCallPlayoutAttemptIsOwned(attempt),
                  Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                return false
            }
            let steadyFloor = IOSHostedCallPlayoutEvidenceFloor(
                callbackCount: diagnostics.playoutCallbackCount,
                frameCount: diagnostics.playoutFrameCount,
                pcmNonzeroSampleCount: diagnostics.playoutPCMNonzeroSampleCount,
                pcmAbsoluteSampleSum: diagnostics.playoutPCMAbsoluteSampleSum,
                failureCount: diagnostics.playoutFailureCount,
                unexpectedRecordingRequestCount: diagnostics.unexpectedRecordingRequestCount,
                inboundAudio: inboundAudio,
                statisticsCollectedAt: snapshot.collectedAt
            )

            audioLifecycle.updateHostedCallRuntimePlayout(
                policyID: attempt.policyID,
                isReady: true
            )
            guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return true }
            guard attempt.authorization.isValid,
                  !attempt.authorization.isRecoveryPending else {
                return fail("The exact hosted-call policy was retired while committing runtime readiness.")
            }
            attempt.steadyFloor = steadyFloor
            attempt.stage = .ready
            guard publishIOSHostedCallPlayoutOracle(
                diagnostics: diagnostics,
                statistics: snapshot,
                for: attempt
            ) else {
                return fail("The committed hosted-call readiness sample could not produce its owned physical oracle.")
            }
            completeIOSHostedCallPlayoutProof(attempt)
            return true

        case .ready:
            guard source == .statistics else { return false }
            guard Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                return fail("The installed hosted-call topology or exact authorization was lost during steady monitoring.")
            }
            guard let floor = attempt.steadyFloor,
                  let snapshot else {
                return fail("The hosted-call steady-state monitor lost its exact counter floor or statistics sample.")
            }

            if let lastCollectedAt = attempt.lastStatisticsCollectedAt {
                if snapshot.collectedAt < lastCollectedAt {
                    return fail("Inbound WebRTC audio statistics regressed to an older steady-state sample.")
                }
                guard snapshot.collectedAt > lastCollectedAt else { return false }
            }
            if let inboundAudio = snapshot.inboundAudio,
               let previous = attempt.lastInboundAudioStatistics,
               Self.iOSHostedCallInboundAudioStatisticsRegressed(
                   from: previous,
                   to: inboundAudio
               ) {
                return fail("Inbound WebRTC audio statistics regressed during steady hosted-call monitoring.")
            }

            attempt.lastStatisticsCollectedAt = snapshot.collectedAt
            guard snapshot.collectedAt > floor.statisticsCollectedAt else { return false }
            guard let inboundAudio = snapshot.inboundAudio,
                  Self.iOSHostedCallInboundAudioHasProofMetric(inboundAudio) else {
                return false
            }
            attempt.lastInboundAudioStatistics = inboundAudio

            let nativeCadenceAdvanced =
                diagnostics.playoutCallbackCount > floor.callbackCount
                && diagnostics.playoutFrameCount > floor.frameCount
            let inboundStatisticsAdvanced =
                Self.iOSHostedCallInboundAudioStatisticsAdvanced(
                    from: floor.inboundAudio,
                    to: inboundAudio
                )
            guard nativeCadenceAdvanced,
                  inboundStatisticsAdvanced else {
                return false
            }
            guard iosHostedCallPlayoutAttemptIsOwned(attempt),
                  Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
                return fail("The exact hosted-call policy changed while resetting its steady-state monitor.")
            }

            attempt.steadyFloor = IOSHostedCallPlayoutEvidenceFloor(
                callbackCount: diagnostics.playoutCallbackCount,
                frameCount: diagnostics.playoutFrameCount,
                pcmNonzeroSampleCount: diagnostics.playoutPCMNonzeroSampleCount,
                pcmAbsoluteSampleSum: diagnostics.playoutPCMAbsoluteSampleSum,
                failureCount: diagnostics.playoutFailureCount,
                unexpectedRecordingRequestCount: diagnostics.unexpectedRecordingRequestCount,
                inboundAudio: inboundAudio,
                statisticsCollectedAt: snapshot.collectedAt
            )
            guard publishIOSHostedCallPlayoutOracle(
                diagnostics: diagnostics,
                statistics: snapshot,
                for: attempt
            ) else {
                return fail("The hosted-call steady sample could not refresh its owned physical oracle.")
            }
            armIOSHostedCallPlayoutTimeout(.steady, for: attempt)
            return false
        }
    }

    private func currentIOSHostedCallPlayoutTime() -> Date {
        #if DEBUG
        if let debugIOSHostedCallPlayoutClock {
            return debugIOSHostedCallPlayoutClock()
        }
        #endif
        return Date()
    }

    private func admitIOSHostedCallDecodedAudio(
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        attempt: IOSHostedCallPlayoutProofAttempt
    ) -> Bool {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt),
              Self.iOSHostedCallInstalledTopologyMatches(diagnostics, attempt: attempt) else {
            return false
        }
        audioLifecycle.updateHostedCallRuntimePlayout(
            policyID: attempt.policyID,
            isReady: false
        )
        guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return true }
        guard attempt.authorization.isValid,
              !attempt.authorization.isRecoveryPending else {
            return failIOSHostedCallPlayoutProof(
                attempt,
                diagnostic: Self.iOSHostedCallPlayoutDiagnostic(
                    "The exact hosted-call policy was retired while admitting decoded audio.",
                    diagnostics: diagnostics,
                    attempt: attempt
                )
            )
        }
        attempt.runtimeGateAdmittedAt = currentIOSHostedCallPlayoutTime()
        attempt.stage = .awaitingEvidenceFloor
        armIOSHostedCallPlayoutTimeout(.evidence, for: attempt)
        return true
    }

    @discardableResult
    private func publishIOSHostedCallPlayoutOracle(
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        statistics snapshot: WebRTCStatisticsSnapshot,
        for attempt: IOSHostedCallPlayoutProofAttempt
    ) -> Bool {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.stage == .ready,
              let steadyFloor = attempt.steadyFloor,
              steadyFloor.statisticsCollectedAt == snapshot.collectedAt,
              let inboundAudio = snapshot.inboundAudio,
              Self.iOSHostedCallInboundAudioHasProofMetric(inboundAudio),
              microphoneIsBlockedByCall,
              Self.iOSHostedCallInstalledTopologyMatches(
                  diagnostics,
                  attempt: attempt
              ) else {
            return false
        }

        // This flag comes only from the lifecycle's privacy-minimal synchronous CallKit
        // aggregate. No call identifier or handle is retained.
        // The counters remain pre-mixer evidence and do not claim final speaker output.
        guard let candidate = WorldwideHostedCallPlayoutOracleSnapshot(
            sessionGeneration: attempt.sessionGeneration,
            policyID: attempt.policyID,
            origin: attempt.origin,
            audioPolicyGeneration: attempt.audioPolicyGeneration,
            authorizationPolicyID: attempt.authorization.policyID,
            authorizationGeneration: attempt.authorization.systemAudioGeneration,
            authorizationIsValid: attempt.authorization.isValid,
            authorizationIsRecoveryPending: attempt.authorization.isRecoveryPending,
            diagnostics: diagnostics,
            inboundAudio: inboundAudio,
            connectedCallKitSnapshot: microphoneIsBlockedByCall
        ) else {
            return false
        }
        guard candidate.outputBusEnabled,
              !candidate.inputBusEnabled,
              candidate.categoryIsMediaPlayback,
              candidate.modeIsDefault,
              candidate.categoryOptionsAreMixWithOthers,
              candidate.remoteIOCreated,
              candidate.audioUnitIsRemoteIO,
              candidate.activeSessionOwnership,
              candidate.hostedCallMode,
              candidate.authorizationIsValid,
              candidate.authorizationIsConsumed,
              candidate.nativeAuthorizationIsValid,
              candidate.nativeAuthorizationIsConsumed,
              candidate.authorizationPolicyMatches,
              candidate.authorizationGenerationMatches,
              candidate.connectedCallKitSnapshot else {
            return false
        }

        if let current = worldwideHostedCallPlayoutOracle {
            let inboundStatisticsAdvanced =
                Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundBytes,
                    to: candidate.inboundBytes
                )
                || Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundPackets,
                    to: candidate.inboundPackets
                )
                || Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundJitterBufferEmittedCount,
                    to: candidate.inboundJitterBufferEmittedCount
                )
                || Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundTotalSamplesReceived,
                    to: candidate.inboundTotalSamplesReceived
                )
                || Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundAudioEnergy,
                    to: candidate.inboundAudioEnergy
                )
                || Self.iOSHostedCallCounterAdvanced(
                    from: current.inboundSamplesDuration,
                    to: candidate.inboundSamplesDuration
                )
            guard current.sessionGeneration == candidate.sessionGeneration,
                  current.policyID == candidate.policyID,
                  current.origin == candidate.origin,
                  current.audioPolicyGeneration == candidate.audioPolicyGeneration,
                  current.systemAudioGeneration == candidate.systemAudioGeneration,
                  current.authorizationGeneration == candidate.authorizationGeneration,
                  current.nativeAuthorizationGeneration
                    == candidate.nativeAuthorizationGeneration,
                  candidate.callbackCount > current.callbackCount,
                  candidate.frameCount > current.frameCount,
                  candidate.failureCount == current.failureCount,
                  candidate.pcmNonzeroSampleCount >= current.pcmNonzeroSampleCount,
                  candidate.pcmAbsoluteSampleSum >= current.pcmAbsoluteSampleSum,
                  candidate.unexpectedRecordingRequestCount
                    == current.unexpectedRecordingRequestCount,
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundBytes,
                      to: candidate.inboundBytes
                  ),
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundPackets,
                      to: candidate.inboundPackets
                  ),
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundJitterBufferEmittedCount,
                      to: candidate.inboundJitterBufferEmittedCount
                  ),
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundTotalSamplesReceived,
                      to: candidate.inboundTotalSamplesReceived
                  ),
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundAudioEnergy,
                      to: candidate.inboundAudioEnergy
                  ),
                  !Self.iOSHostedCallCounterRegressed(
                      from: current.inboundSamplesDuration,
                      to: candidate.inboundSamplesDuration
                  ),
                  inboundStatisticsAdvanced else {
                return false
            }
        }

        worldwideHostedCallPlayoutOracle = candidate
        return true
    }

    private func completeIOSHostedCallPlayoutProof(
        _ attempt: IOSHostedCallPlayoutProofAttempt
    ) {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.stage == .ready,
              attempt.steadyFloor != nil else {
            return
        }
        let proofTask = iosHostedCallPlayoutProofTask
        iosHostedCallPlayoutProofTask = nil
        proofTask?.cancel()
        armIOSHostedCallPlayoutTimeout(.steady, for: attempt)
    }

    private func iosHostedCallPlayoutAttemptIsOwned(
        _ attempt: IOSHostedCallPlayoutProofAttempt
    ) -> Bool {
        guard iosHostedCallPlayoutAttempt === attempt,
              iosHostedCallPlayoutAuthorization === attempt.authorization,
              iosHostedCallPlayoutProofAttemptID == attempt.proofAttemptID,
              iosHostedCallPlayoutCounterWindowID == attempt.counterWindowID,
              iosHostedCallPlayoutScopeID == attempt.scopeID,
              iosHostedCallPlayoutPolicyID == attempt.policyID,
              attempt.policyID == attempt.authorization.policyID,
              attempt.origin == attempt.authorization.origin,
              attempt.authorizationIdentity == ObjectIdentifier(attempt.authorization),
              attempt.sessionGeneration == sessionGeneration,
              attempt.audioPolicyGeneration == audioPolicyGeneration,
              attempt.expectedPeerIdentity == ObjectIdentifier(attempt.expectedPeer),
              peer === attempt.expectedPeer,
              audioLifecycle.hostedCallScopeID(
                for: attempt.authorization
              ) == attempt.scopeID else {
            return false
        }
        return true
    }

    private func retireIOSHostedCallPlayoutAttempt(
        _ expectedAttempt: IOSHostedCallPlayoutProofAttempt? = nil
    ) {
        if let expectedAttempt,
           iosHostedCallPlayoutAttempt !== expectedAttempt {
            return
        }
        worldwideHostedCallPlayoutOracle = nil
        let authorization = iosHostedCallPlayoutAttempt?.authorization
            ?? iosPendingStartupConnectedCallPlayout?.authorization
            ?? iosHostedCallPlayoutAuthorization
        authorization?.revoke()
        iosHostedCallPlayoutProofTask?.cancel()
        iosHostedCallPlayoutProofTimeoutTask?.cancel()
        iosHostedCallPlayoutProofTask = nil
        iosHostedCallPlayoutProofTimeoutTask = nil
        iosPendingStartupConnectedCallPlayout = nil
        iosHostedCallPlayoutAttempt = nil
        iosHostedCallPlayoutAuthorization = nil
        iosHostedCallPlayoutProofAttemptID = nil
        iosHostedCallPlayoutCounterWindowID = nil
        iosHostedCallPlayoutScopeID = nil
        iosHostedCallPlayoutPolicyID = nil
    }

    private func failIOSHostedCallPlayoutProofTimeout(
        _ attempt: IOSHostedCallPlayoutProofAttempt,
        phase: IOSHostedCallPlayoutTimeoutPhase,
        timeoutID: UUID
    ) {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt),
              attempt.timeoutPhase == phase,
              attempt.timeoutID == timeoutID else { return }
        let diagnostic: String
        switch phase {
        case .setup:
            guard attempt.stage == .awaitingNativeQuiescence
                    || attempt.stage == .awaitingNativeRecovery else { return }
            diagnostic = "Hosted-call playout setup timed out in \(Self.iOSHostedCallPlayoutStageDescription(attempt.stage)) after \(attempt.pollOrdinal) polls and \(attempt.recoveryRequestCount) native recovery request(s)."
        case .evidence:
            guard attempt.stage == .awaitingEvidenceFloor
                    || attempt.stage == .awaitingFreshEvidence else { return }
            diagnostic = "Hosted-call playout evidence timed out in \(Self.iOSHostedCallPlayoutStageDescription(attempt.stage)) after runtime-gate admission."
        case .steady:
            guard attempt.stage == .ready else { return }
            diagnostic = "Hosted-call playout steady-state monitoring stalled without native callback/frame cadence and inbound RTP advancement."
        }
        _ = failIOSHostedCallPlayoutProof(
            attempt,
            diagnostic: diagnostic
        )
    }

    @discardableResult
    private func failIOSHostedCallPlayoutProof(
        _ attempt: IOSHostedCallPlayoutProofAttempt,
        diagnostic: String
    ) -> Bool {
        guard iosHostedCallPlayoutAttemptIsOwned(attempt) else { return false }
        audioLifecycle.failHostedCallRuntimePlayout(
            policyID: attempt.policyID,
            authorization: attempt.authorization,
            failureMessage: "The iPhone could not start call-compatible WebRTC playback.",
            diagnostic: diagnostic
        )
        retireIOSHostedCallPlayoutAttempt(attempt)
        return true
    }

    private static func iOSHostedCallNativeQuiescenceIsVisible(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        diagnostics.initialized
            && !diagnostics.playoutInitialized
            && !diagnostics.playing
            && !diagnostics.sessionActive
            && !diagnostics.ownsSessionActivation
            && !diagnostics.remoteIOCreated
            && !diagnostics.inputBusEnabled
            && !diagnostics.outputBusEnabled
            && diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
    }

    private static func iOSHostedCallInstalledTopologyMatches(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        attempt: IOSHostedCallPlayoutProofAttempt
    ) -> Bool {
        guard let nativeCounterFloor = attempt.nativeCounterFloor else {
            return false
        }
        let authorizationGeneration = attempt.authorization.systemAudioGeneration
        return attempt.authorization.isValid
            && !attempt.authorization.isRecoveryPending
            && authorizationGeneration != 0
            && diagnostics.hostedCallAuthorizationValid
            && !diagnostics.hostedCallRecoveryPending
            && diagnostics.hostedCallOrigin == attempt.origin
            && diagnostics.systemAudioGeneration == authorizationGeneration
            && diagnostics.hostedCallAuthorizationGeneration == authorizationGeneration
            && diagnostics.initialized
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
            && !diagnostics.categoryIsMediaPlayAndRecord
            && diagnostics.modeIsDefault
            && !diagnostics.categoryOptionsAreEmpty
            && diagnostics.categoryOptionsAreMixWithOthers
            && diagnostics.routeSharingPolicyIsDefault
            && diagnostics.hasOutputRoute
            && diagnostics.hostedCallMode
            && diagnostics.audioUnitSubType == kAudioUnitSubType_RemoteIO
            && diagnostics.failureCode == 0
            && diagnostics.lastLifecycleStatus == noErr
            && diagnostics.lastPlayoutStatus == noErr
            && diagnostics.failureMessage == nil
            && diagnostics.playoutFailureCount == nativeCounterFloor.failureCount
            && diagnostics.unexpectedRecordingRequestCount == nativeCounterFloor.unexpectedRecordingRequestCount
    }

    private static func iOSHostedCallLifecycleFailureIsVisible(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        diagnostics.failureCode != 0
            || diagnostics.lastLifecycleStatus != noErr
            || diagnostics.lastPlayoutStatus != noErr
            || diagnostics.failureMessage != nil
    }

    private static func iOSHostedCallInboundAudioHasProofMetric(
        _ statistics: WebRTCAudioStatistics
    ) -> Bool {
        statistics.bytes != nil
            || statistics.packets != nil
            || statistics.jitterBufferEmittedCount != nil
            || statistics.totalSamplesReceived != nil
            || statistics.totalAudioEnergy?.isFinite == true
            || statistics.totalSamplesDuration?.isFinite == true
    }

    private static func iOSHostedCallInboundAudioStatisticsRegressed(
        from previous: WebRTCAudioStatistics,
        to current: WebRTCAudioStatistics
    ) -> Bool {
        iOSHostedCallCounterRegressed(from: previous.bytes, to: current.bytes)
            || iOSHostedCallCounterRegressed(from: previous.packets, to: current.packets)
            || iOSHostedCallCounterRegressed(from: previous.jitterBufferEmittedCount, to: current.jitterBufferEmittedCount)
            || iOSHostedCallCounterRegressed(from: previous.totalSamplesReceived, to: current.totalSamplesReceived)
            || iOSHostedCallCounterRegressed(from: previous.totalAudioEnergy, to: current.totalAudioEnergy)
            || iOSHostedCallCounterRegressed(from: previous.totalSamplesDuration, to: current.totalSamplesDuration)
    }

    private static func iOSHostedCallInboundAudioStatisticsAdvanced(
        from floor: WebRTCAudioStatistics,
        to current: WebRTCAudioStatistics
    ) -> Bool {
        iOSHostedCallCounterAdvanced(from: floor.bytes, to: current.bytes)
            || iOSHostedCallCounterAdvanced(from: floor.packets, to: current.packets)
            || iOSHostedCallCounterAdvanced(from: floor.jitterBufferEmittedCount, to: current.jitterBufferEmittedCount)
            || iOSHostedCallCounterAdvanced(from: floor.totalSamplesReceived, to: current.totalSamplesReceived)
            || iOSHostedCallCounterAdvanced(from: floor.totalAudioEnergy, to: current.totalAudioEnergy)
            || iOSHostedCallCounterAdvanced(from: floor.totalSamplesDuration, to: current.totalSamplesDuration)
    }

    private static func iOSHostedCallCounterRegressed(
        from previous: UInt64?,
        to current: UInt64?
    ) -> Bool {
        guard let previous else { return false }
        guard let current else { return true }
        return current < previous
    }

    private static func iOSHostedCallCounterRegressed(
        from previous: Double?,
        to current: Double?
    ) -> Bool {
        guard let previous else { return false }
        guard let current else { return true }
        guard previous.isFinite, current.isFinite else { return true }
        return current < previous
    }

    private static func iOSHostedCallCounterAdvanced(
        from floor: UInt64?,
        to current: UInt64?
    ) -> Bool {
        guard let floor, let current else { return false }
        return current > floor
    }

    private static func iOSHostedCallCounterAdvanced(
        from floor: Double?,
        to current: Double?
    ) -> Bool {
        guard let floor, let current,
              floor.isFinite, current.isFinite else {
            return false
        }
        return current > floor
    }

    private static func iOSHostedCallPlayoutTimeoutDuration(
        for phase: IOSHostedCallPlayoutTimeoutPhase
    ) -> Duration {
        switch phase {
        case .setup:
            iosHostedCallPlayoutSetupTimeout
        case .evidence:
            iosHostedCallPlayoutEvidenceTimeout
        case .steady:
            iosHostedCallPlayoutSteadyTimeout
        }
    }

    private static func iOSHostedCallPlayoutTimeoutPhaseDescription(
        _ phase: IOSHostedCallPlayoutTimeoutPhase
    ) -> String {
        switch phase {
        case .setup:
            "setup"
        case .evidence:
            "evidence"
        case .steady:
            "steady"
        }
    }

    private static func iOSHostedCallPlayoutStageDescription(
        _ stage: IOSHostedCallPlayoutProofStage
    ) -> String {
        switch stage {
        case .awaitingNativeQuiescence:
            "awaiting-native-quiescence"
        case .awaitingNativeRecovery:
            "awaiting-native-recovery"
        case .awaitingEvidenceFloor:
            "awaiting-evidence-floor"
        case .awaitingFreshEvidence:
            "awaiting-fresh-evidence"
        case .ready:
            "ready"
        }
    }

    private static func iOSHostedCallPlayoutDiagnostic(
        _ context: String,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        attempt: IOSHostedCallPlayoutProofAttempt
    ) -> String {
        [
            context,
            "stage=\(iOSHostedCallPlayoutStageDescription(attempt.stage))",
            "policyID=\(attempt.policyID.uuidString)",
            "origin=\(attempt.origin.rawValue)",
            "nativeOrigin=\(diagnostics.hostedCallOrigin?.rawValue ?? "unspecified")",
            "authorizationValid=\(attempt.authorization.isValid)",
            "authorizationPending=\(attempt.authorization.isRecoveryPending)",
            "authorizationGeneration=\(attempt.authorization.systemAudioGeneration)",
            "systemGeneration=\(diagnostics.systemAudioGeneration)",
            "hostedAuthorizationGeneration=\(diagnostics.hostedCallAuthorizationGeneration)",
            "hostedMode=\(diagnostics.hostedCallMode)",
            "hostedDiagnosticValid=\(diagnostics.hostedCallAuthorizationValid)",
            "hostedDiagnosticPending=\(diagnostics.hostedCallRecoveryPending)",
            "initialized=\(diagnostics.initialized)",
            "playoutInitialized=\(diagnostics.playoutInitialized)",
            "playing=\(diagnostics.playing)",
            "sessionActive=\(diagnostics.sessionActive)",
            "ownsActivation=\(diagnostics.ownsSessionActivation)",
            "remoteIO=\(diagnostics.remoteIOCreated)",
            "input=\(diagnostics.inputBusEnabled)",
            "output=\(diagnostics.outputBusEnabled)",
            "recoveryRequired=\(diagnostics.recoveryRequired)",
            "explicitResume=\(diagnostics.explicitResumeRequired)",
            "hasRoute=\(diagnostics.hasOutputRoute)",
            "failure=\(diagnostics.failureCode)",
            "lifecycleStatus=\(diagnostics.lastLifecycleStatus)",
            "playoutStatus=\(diagnostics.lastPlayoutStatus)",
            "callbacks=\(diagnostics.playoutCallbackCount)",
            "frames=\(diagnostics.playoutFrameCount)",
            "nonzeroPCM=\(diagnostics.playoutPCMNonzeroSampleCount)",
            "absolutePCM=\(diagnostics.playoutPCMAbsoluteSampleSum)",
            "failures=\(diagnostics.playoutFailureCount)",
            "recordRequests=\(diagnostics.unexpectedRecordingRequestCount)",
            "failureMessage=\(diagnostics.failureMessage ?? "none")",
        ].joined(separator: "|")
    }

    private func iosPlayoutProofAttemptIsOwned(
        _ attempt: IOSPlayoutProofAttempt
    ) -> Bool {
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall,
              iosPlayoutProofAttempt === attempt,
              attempt.sessionGeneration == sessionGeneration,
              attempt.audioPolicyGeneration == audioPolicyGeneration else { return false }
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
              attempt.audioPolicyGeneration == handle.audioPolicyGeneration,
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
            failureMessage: "The iPhone 48 kHz stereo render path did not start.",
            diagnostic: "RemoteIO produced no verified playout callback within two seconds.",
            categoryProofClaim: attempt.categoryProofClaim
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
            guard authorization.terminalGeneration
                    == authorization.generation,
                  authorization.terminalOutcome == .accepted else {
                // Pending, rejected, and revoked claims cannot move a recovery attempt onto a
                // healthy post-recovery floor. The bounded proof timeout owns eventual cleanup.
                return false
            }
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
              iOSPlayoutInputPolicyMatches(diagnostics),
              iOSPlayoutCategoryProofPolicyMatches(
                diagnostics,
                claim: attempt.categoryProofClaim
              ),
              !diagnostics.recoveryRequired,
              !diagnostics.explicitResumeRequired else {
            return failIOSPlayoutProof(attempt, diagnostics: diagnostics)
        }

        if let milestone = attempt.postCallRecoveryMilestone,
           attempt.recoveryBaseline != nil,
           attempt.stage == .awaitingPostRecoveryFloor,
           attempt.recoveryAuthorization?
                .hasAcceptedTerminalOutcome == true,
           !diagnostics.inputBusEnabled,
           WorldwideAudioPlayoutOracleSnapshot
                .routeInvariantsHold(diagnostics) {
            // Native consumption plus this exact output-only installed-policy sample is the
            // call-end microphone milestone. Fresh callback/frame advancement remains the
            // ordinary playout proof, but is deliberately not an input-admission prerequisite.
            guard audioLifecycle.completePostCallMicrophoneRecovery(
                milestone
            ) else {
                // A synchronous CallKit re-sample may discover a replacement live call while
                // evaluating this otherwise healthy output-only sample. That is a rejected
                // milestone, not a successful terminal proof.
                return false
            }
            // The callback may synchronously start microphone admission, rotate policy, and
            // retire this attempt. Continue ordinary proof only when no input intent did so.
            guard iosPlayoutProofAttemptIsOwned(attempt) else {
                return true
            }
        }

        attempt.lastCallbackCount = diagnostics.playoutCallbackCount
        attempt.lastFrameCount = diagnostics.playoutFrameCount
        attempt.lastFailureCount = diagnostics.playoutFailureCount

        if attempt.stage == .awaitingInitialFloor
            || attempt.stage == .awaitingPostRecoveryFloor {
            attempt.callbackFloor = diagnostics.playoutCallbackCount
            attempt.frameFloor = diagnostics.playoutFrameCount
            attempt.stage = .awaitingFreshEvidence
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                categoryProofClaim: attempt.categoryProofClaim
            )
            return false
        }

        guard attempt.stage == .awaitingFreshEvidence,
              let callbackFloor = attempt.callbackFloor,
              let frameFloor = attempt.frameFloor else { return false }

        let renderInputInvariantsHold = iOSPlayoutRouteInvariantsHold(
            diagnostics
        )
        let hasFreshCallbackAndFrames = diagnostics.playoutCallbackCount > callbackFloor
            && diagnostics.playoutFrameCount > frameFloor

        guard renderInputInvariantsHold, hasFreshCallbackAndFrames else {
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                categoryProofClaim: attempt.categoryProofClaim
            )
            return false
        }

        verifiedAudioPolicyGeneration = attempt.audioPolicyGeneration
        if attempt.recoveryBaseline != nil {
            audioPolicyRequiresFreshRecovery = false
        }
        if let sourcePeer = attempt.expectedPeer ?? peer {
            publishIOSPlayoutOracle(
                diagnostics,
                from: sourcePeer,
                generation: attempt.sessionGeneration,
                policyGeneration: attempt.audioPolicyGeneration,
                inboundAudio: statistics?.inboundAudio
            )
        }
        retireIOSPlayoutRecoveryAttempt(attempt)
        audioLifecycle.updateRuntimePlayout(
            isReady: true,
            categoryProofClaim: attempt.categoryProofClaim
        )
        return true
    }

    private static func iOSPlayoutFailureMessage(
        inputPolicyMatches: Bool,
        diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> String {
        guard inputPolicyMatches else {
            return
                "The iPhone audio input state no longer matches the current microphone authorization."
        }

        let categoryMatchesInputPolicy: Bool
        if diagnostics.inputBusEnabled {
            categoryMatchesInputPolicy =
                !diagnostics.categoryIsMediaPlayback
                && diagnostics.categoryIsMediaPlayAndRecord
        } else {
            categoryMatchesInputPolicy =
                diagnostics.categoryIsMediaPlayback
                && !diagnostics.categoryIsMediaPlayAndRecord
        }

        guard categoryMatchesInputPolicy,
              diagnostics.modeIsDefault,
              diagnostics.outputChannelCount == 2,
              abs(diagnostics.sampleRate - 48_000) < 1 else {
            return
                "The iPhone route no longer provides the required 48 kHz stereo playback path."
        }

        return "The iPhone 48 kHz stereo render path could not start."
    }

    #if DEBUG
    static func debugIOSPlayoutFailureMessage(
        inputPolicyMatches: Bool,
        diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> String {
        iOSPlayoutFailureMessage(
            inputPolicyMatches: inputPolicyMatches,
            diagnostics: diagnostics
        )
    }
    #endif

    @discardableResult
    private func failIOSPlayoutProof(
        _ attempt: IOSPlayoutProofAttempt,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        diagnosticOverride: String? = nil
    ) -> Bool {
        guard iosPlayoutProofAttemptIsOwned(attempt) else { return false }
        let message = Self.iOSPlayoutFailureMessage(
            inputPolicyMatches: iOSPlayoutInputPolicyMatches(diagnostics),
            diagnostics: diagnostics
        )
        let diagnostic = diagnosticOverride
            ?? diagnostics.failureMessage
            ?? "RemoteIO failure=\(diagnostics.failureCode), status=\(diagnostics.lastLifecycleStatus), renderStatus=\(diagnostics.lastPlayoutStatus), callbacks=\(diagnostics.playoutCallbackCount), failures=\(diagnostics.playoutFailureCount), recordRequests=\(diagnostics.unexpectedRecordingRequestCount)."
        retireIOSPlayoutRecoveryAttempt(attempt)
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            failureMessage: message,
            diagnostic: diagnostic,
            categoryProofClaim: attempt.categoryProofClaim
        )
        return true
    }

    // MARK: - Control acknowledgements and ICE recovery

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
        recordViewerTransportHealthProof()
        audioLifecycle.transportBecameHealthy()
        establishAutomaticIPhoneMicrophoneIntentIfEligible()
        continueIPhoneMicrophoneEnablementIfPossible()
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
            lastError = "The Mac has not allowed opensteamer to post mouse and keyboard events."
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
    // MARK: - Deterministic race-test seams

    func debugInstallStatisticsStarter(
        _ starter: @escaping @MainActor (WebRTCPeer) async throws -> Void
    ) {
        debugStatisticsStarter = starter
    }

    func debugInstallMacHostedCallChallengeSender(
        _ sender: @escaping @MainActor (
            WebRTCPeer,
            WebRTCMacHostedCallChallenge
        ) async throws -> Void
    ) {
        debugMacHostedCallChallengeSender = sender
    }

    func debugInstallMacHostedCallChallengeAutomaticRetryWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugMacHostedCallChallengeAutomaticRetryWaiter = waiter
    }

    func debugMacHostedCallCapabilityRetryContextForTests()
        -> WorldwideMacHostedCallCapabilityRetryDebugContext? {
        guard let peer else { return nil }
        return WorldwideMacHostedCallCapabilityRetryDebugContext(
            peer: peer,
            sessionGeneration: sessionGeneration,
            negotiationGeneration:
                macHostedCallNegotiationGeneration
        )
    }

    func debugDeliverMacHostedCallCapabilityNegotiatedForTests(
        _ context: WorldwideMacHostedCallCapabilityRetryDebugContext
    ) {
        macHostedCallAnswerWasForwardedIfCurrent(
            sourcePeer: context.peer,
            sourceGeneration: context.sessionGeneration,
            sourceNegotiationGeneration:
                context.negotiationGeneration
        )
    }

    func debugBeginMacHostedCallNegotiationForTests() {
        beginMacHostedCallNegotiationBoundary()
    }

    func debugWaitForMacHostedCallChallengeSendForTests() async {
        while let task = macHostedCallChallengeSendTask {
            await task.value
        }
    }

    /// Keeps production `connect` ownership active without opening a real WebSocket, allowing
    /// reentrancy tests to prove whether a replacement connect is accepted deterministically.
    func debugInstallSessionRunner(_ runner: @escaping @MainActor () async -> Void) {
        debugSessionRunner = runner
    }

    func debugInstallIPhoneMicrophonePermissionRequester(
        _ requester: @escaping @MainActor () async -> Bool
    ) {
        debugIPhoneMicrophonePermissionRequester = requester
    }

    func debugCacheIPhoneMicrophonePermissionForTests() {
        microphonePermissionGranted = true
    }

    func debugIOSPlayoutInputPolicyMatchesForTests(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        iOSPlayoutInputPolicyMatches(diagnostics)
    }

    func debugInstallIPhoneMicrophonePermissionResolutionObserver(
        _ observer: @escaping @MainActor (Bool) -> Void
    ) {
        debugIPhoneMicrophonePermissionResolutionObserver = observer
    }

    func debugInstallIPhoneMicrophoneEnableAttemptObserver(
        _ observer: @escaping @MainActor () -> Void
    ) {
        debugIPhoneMicrophoneEnableAttemptObserver = observer
    }

    func debugInstallIPhoneMicrophoneNativeHandlers(
        enable: @escaping @MainActor (
            WebRTCIOSMicrophoneAuthorization
        ) async throws -> Void,
        disable: @escaping @MainActor (
            WebRTCIOSMicrophoneAuthorization?,
            WebRTCIOSOutputOnlyMicrophoneToken?
        ) async -> Bool
    ) {
        debugIPhoneMicrophoneNativeEnableHandler = enable
        debugIPhoneMicrophoneNativeDisableHandler = disable
    }

    func debugInstallIPhoneMicrophoneDidCommitObserver(
        _ observer: @escaping @MainActor (
            WebRTCIOSMicrophoneAuthorization
        ) -> Void
    ) {
        debugIPhoneMicrophoneDidCommitObserver = observer
    }

    func debugInstallIPhoneMicrophoneSenderStatisticsReader(
        _ reader: @escaping @MainActor (
            WebRTCPeer
        ) async -> WebRTCIPhoneMicrophoneSenderStatistics?
    ) {
        debugIPhoneMicrophoneSenderStatisticsReader = reader
    }

    func debugInstallBeforeRetiredPeerClose(
        _ hook: @escaping @MainActor () async -> Void
    ) {
        debugBeforeRetiredPeerClose = hook
    }

    func debugDenyIPhoneMicrophonePermissionForTests() {
        handleIPhoneMicrophonePermissionDenied()
    }

    func debugRefreshRawMicrophoneOracleForTests(
        from sourcePeer: WebRTCPeer
    ) async {
        await refreshIOSRawMicrophoneOracle(
            from: sourcePeer,
            generation: sessionGeneration
        )
    }

    var debugIPhoneMicrophoneAuthorizationForTests:
        WebRTCIOSMicrophoneAuthorization? {
        microphoneAuthorization
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

    func debugInstallIOSHostedCallPlayoutRecoveryRequester(
        _ requester: @escaping @MainActor (
            WebRTCPeer,
            WebRTCIOSHostedCallPlayoutAuthorization
        ) -> Void
    ) {
        debugIOSHostedCallPlayoutRecoveryRequester = requester
    }

    func debugInstallIOSHostedCallPlayoutRequestPreflightWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugIOSHostedCallPlayoutRequestPreflightWaiter = waiter
    }

    func debugInstallIOSHostedCallPlayoutPollWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugIOSHostedCallPlayoutPollWaiter = waiter
    }

    func debugInstallIOSHostedCallPlayoutSetupTimeoutWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugIOSHostedCallPlayoutSetupTimeoutWaiter = waiter
    }

    func debugInstallIOSHostedCallPlayoutEvidenceTimeoutWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugIOSHostedCallPlayoutEvidenceTimeoutWaiter = waiter
    }

    func debugInstallIOSHostedCallPlayoutSteadyTimeoutWaiter(
        _ waiter: @escaping @MainActor () async -> Void
    ) {
        debugIOSHostedCallPlayoutSteadyTimeoutWaiter = waiter
    }

    func debugInstallIOSHostedCallPlayoutClock(
        _ clock: @escaping @MainActor () -> Date
    ) {
        debugIOSHostedCallPlayoutClock = clock
    }

    func debugDriveIOSHostedCallStatisticsForTests(
        _ snapshot: WebRTCStatisticsSnapshot,
        from sourcePeer: WebRTCPeer,
        generation: UUID
    ) async {
        await handleWorldwideSessionStatistics(
            snapshot,
            from: sourcePeer,
            generation: generation
        )
    }

    func debugIOSHostedCallPlayoutProjectionForTests()
        -> WorldwideIOSHostedCallPlayoutDebugProjection? {
        guard let attempt = iosHostedCallPlayoutAttempt else { return nil }

        func projectedFloor(
            _ floor: IOSHostedCallPlayoutEvidenceFloor?
        ) -> WorldwideIOSHostedCallPlayoutDebugFloor? {
            guard let floor else { return nil }
            let inboundAudio = floor.inboundAudio
            return WorldwideIOSHostedCallPlayoutDebugFloor(
                callbackCount: floor.callbackCount,
                frameCount: floor.frameCount,
                pcmNonzeroSampleCount: floor.pcmNonzeroSampleCount,
                pcmAbsoluteSampleSum: floor.pcmAbsoluteSampleSum,
                failureCount: floor.failureCount,
                unexpectedRecordingRequestCount: floor.unexpectedRecordingRequestCount,
                statisticsCollectedAt: floor.statisticsCollectedAt,
                inboundBytes: inboundAudio.bytes,
                inboundPackets: inboundAudio.packets,
                inboundJitterBufferEmittedCount: inboundAudio.jitterBufferEmittedCount,
                inboundTotalSamplesReceived: inboundAudio.totalSamplesReceived,
                inboundTotalAudioEnergy: inboundAudio.totalAudioEnergy,
                inboundTotalSamplesDuration: inboundAudio.totalSamplesDuration
            )
        }

        let timeoutTaskIsRetained = iosHostedCallPlayoutProofTimeoutTask != nil
        let proofDeadlineIsArmed =
            timeoutTaskIsRetained
            && (attempt.timeoutPhase == .setup
                || attempt.timeoutPhase == .evidence)
        let steadyMonitorIsArmed =
            timeoutTaskIsRetained
            && attempt.timeoutPhase == .steady
            && attempt.stage == .ready

        return WorldwideIOSHostedCallPlayoutDebugProjection(
            stage: Self.iOSHostedCallPlayoutStageDescription(attempt.stage),
            proofAttemptID: attempt.proofAttemptID,
            counterWindowID: attempt.counterWindowID,
            scopeID: attempt.scopeID,
            policyID: attempt.policyID,
            origin: attempt.origin,
            authorizationIdentity: attempt.authorizationIdentity,
            authorizationIsValid: attempt.authorization.isValid,
            authorizationIsRecoveryPending: attempt.authorization.isRecoveryPending,
            authorizationSystemAudioGeneration: attempt.authorization.systemAudioGeneration,
            sessionGeneration: attempt.sessionGeneration,
            audioPolicyGeneration: attempt.audioPolicyGeneration,
            expectedPeerIdentity: attempt.expectedPeerIdentity,
            pollOrdinal: attempt.pollOrdinal,
            recoveryRequestCount: attempt.recoveryRequestCount,
            nextRecoveryRequestPollOrdinal: attempt.nextRecoveryRequestPollOrdinal,
            runtimeGateAdmittedAt: attempt.runtimeGateAdmittedAt,
            evidenceFloor: projectedFloor(attempt.evidenceFloor),
            steadyFloor: projectedFloor(attempt.steadyFloor),
            timeoutPhase: attempt.timeoutPhase.map {
                Self.iOSHostedCallPlayoutTimeoutPhaseDescription($0)
            },
            timeoutID: attempt.timeoutID,
            pollingTaskIsRetained: iosHostedCallPlayoutProofTask != nil,
            timeoutTaskIsRetained: timeoutTaskIsRetained,
            proofDeadlineIsArmed: proofDeadlineIsArmed,
            steadyMonitorIsArmed: steadyMonitorIsArmed
        )
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
        // This hook tests publication/race mechanics directly; production can arm this token
        // only after a fresh proof window observes advancing callbacks and frames.
        verifiedAudioPolicyGeneration = audioPolicyGeneration
        let snapshot = statistics ?? WebRTCStatisticsSnapshot()
        await refreshIOSPlayoutOracle(
            from: sourcePeer,
            generation: sessionGeneration,
            statistics: snapshot
        )
    }

    var debugIOSPlayoutRecoveryIsAuthorized: Bool {
        audioPlayoutRecoveryAuthorization?.isValid == true
    }

    var debugAudioPolicyGeneration: UUID {
        audioPolicyGeneration
    }

    func debugRotateAudioPolicyForTests() {
        invalidateAudioPolicyProof(requiresFreshRecovery: false)
    }

    var debugIOSPlayoutRecoveryAuthorizationForTests:
        WebRTCIOSPlayoutRecoveryAuthorization? {
        audioPlayoutRecoveryAuthorization
    }

    func debugStartIOSPlayoutProofAttemptForTests(
        requestRecovery: Bool,
        preRecoveryDiagnostics: WebRTCIOSPlayoutDiagnostics? = nil,
        expectedPeer: WebRTCPeer? = nil,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone? = nil,
        categoryProofClaim:
            WorldwideAudioCategoryProofClaim? = nil
    ) -> WorldwideIOSPlayoutProofDebugHandle {
        precondition(!hasOwnedIOSHostedCallPlayoutPolicy)
        if let expectedPeer {
            precondition(peer === expectedPeer)
        }
        retireIOSPlayoutRecoveryAttempt()
        audioPlayoutProofTask?.cancel()
        audioPlayoutProofTask = nil
        audioLifecycle.updateRuntimePlayout(
            isReady: false,
            categoryProofClaim: categoryProofClaim
        )

        let requiresRecovery = requestRecovery || audioPolicyRequiresFreshRecovery
        let authorization = requiresRecovery
            ? WebRTCIOSPlayoutRecoveryAuthorization()
            : nil
        let attempt = IOSPlayoutProofAttempt(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: audioPolicyGeneration,
            expectedPeer: expectedPeer,
            postCallRecoveryMilestone:
                requiresRecovery
                    ? postCallRecoveryMilestone
                    : nil,
            categoryProofClaim: categoryProofClaim,
            stage: requiresRecovery
                ? .awaitingRecoveryBaseline
                : .awaitingInitialFloor
        )
        if requiresRecovery {
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
            sessionGeneration: attempt.sessionGeneration,
            audioPolicyGeneration: attempt.audioPolicyGeneration
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
                sessionGeneration: attempt.sessionGeneration,
                audioPolicyGeneration: attempt.audioPolicyGeneration
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

    func debugInstallScreenSessionForTests(
        peer newPeer: WebRTCPeer,
        generation: UUID = UUID(),
        visible: Bool = false,
        provenance: MediaSessionProvenance = .unauthenticated
    ) {
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            clearRequestHistory: true
        )
        peer = newPeer
        sessionGeneration = generation
        automaticMicrophoneEligibleSessionGeneration =
            provenance == .authenticatedPairedCoordinatorHandoff ? generation : nil
        automaticMicrophoneAttemptedSessionGeneration = nil
        manuallyDisabledMicrophoneSessionGeneration = nil
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneAdmissionDeferredUntilTransportProof = nil
        viewerTransportHealthProofRevision = 0
        microphoneAdmissionCleanupID = nil
        isMicrophoneAdmissionCleanupInProgress = false
        isPeerConnected = true
        iceIsConnected = true
        isControlChannelReady = true
        isScreenVisible = visible
        acceptsActiveScreenAcknowledgement = visible
        remoteHideRequired = visible
    }

    func debugMarkViewerTransportHealthyForAutomaticMicrophoneTests() async {
        isPeerConnected = true
        iceIsConnected = true
        isControlChannelReady = true
        recoveryProofRequired = false
        await markViewerTransportHealthyIfPossible(.connected)
    }

    func debugMarkViewerTransportUncertainForAutomaticMicrophoneTests() {
        isPeerConnected = false
        markTransportUncertain("Recovering secure media")
    }

    func debugCompleteRecoveryProbeForAutomaticMicrophoneTests() async {
        guard let peer else { return }

        recoveryProofEpoch &+= 1
        if recoveryProofEpoch == 0 {
            recoveryProofEpoch = 1
        }
        recoveryProofRequired = true
        let requestID: UInt64 = 0xA11C_EC01
        let requestKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: sessionGeneration,
            requestID: requestID
        )
        pendingRecoveryProbe = PendingRecoveryProbe(
            sessionGeneration: sessionGeneration,
            epoch: recoveryProofEpoch,
            requestKey: requestKey,
            expectedPeer: peer
        )
        await completeRecoveryProbe(
            with: WebRTCControlAcknowledgement(
                id: requestID,
                state: .inactive
            ),
            inputAuthorization: nil,
            sourcePeer: peer,
            sourceGeneration: sessionGeneration
        )
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

    // MARK: - Session teardown and transport health

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
        recordViewerTransportHealthProof()
        audioLifecycle.transportBecameHealthy()
        await activatePendingIOSStartupConnectedCallPlayoutIfPossible()
        establishAutomaticIPhoneMicrophoneIntentIfEligible()
        continueIPhoneMicrophoneEnablementIfPossible()
        await recoveryCoordinator?.iceStateChanged(state)
    }

    private func recordViewerTransportHealthProof() {
        viewerTransportHealthProofRevision &+= 1
        guard let deferred = microphoneAdmissionDeferredUntilTransportProof,
              deferred.sessionGeneration == sessionGeneration,
              viewerTransportHealthProofRevision > deferred.proofRevision,
              !isMicrophoneAdmissionCleanupInProgress else {
            return
        }
        microphoneAdmissionDeferredUntilTransportProof = nil
        microphoneError = nil
    }

    private func markTransportUncertain(
        _ state: String,
        requiresProof: Bool = false
    ) {
        transportAuthorizationGeneration = UUID()
        invalidateMacHostedCallEvidence(notifyLifecycle: false)
        retireIOSHostedCallPlayoutAttempt()
        audioLifecycle.transportBecameUncertain()
        suspendIPhoneMicrophone(
            stateText: "Paused — reconnecting",
            preserveIntent: true,
            reprovePlayout: false
        )
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

    /// Runs on MainActor while the peer's ordered native-event boundary is suspended. It retires
    /// stale category ownership and arms playback/default before the peer performs native teardown.
    private func prepareIPhoneMicrophoneForTransportSuspension(
        retirementContext: WebRTCIOSMicrophoneRetirementContext,
        expectedPeerIdentity: ObjectIdentifier,
        expectedSessionGeneration: UUID
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        guard expectedSessionGeneration == sessionGeneration,
              let peer,
              ObjectIdentifier(peer) == expectedPeerIdentity else {
            return nil
        }

        retireMacHostedCallChallengeSendAttempt()
        retireIOSHostedCallPlayoutAttempt()
        invalidateMacHostedCallEvidence(notifyLifecycle: false)
        audioLifecycle.transportBecameUncertain()
        suspendIPhoneMicrophone(
            stateText: "Paused — reconnecting",
            preserveIntent: true,
            reprovePlayout: false,
            performNativeTeardown: false
        )

        var replacementToken:
            WebRTCIOSOutputOnlyMicrophoneToken?
        while true {
            if let executingToken = retirementContext.executingToken {
                if let replacementToken,
                   replacementToken !== executingToken {
                    audioLifecycle
                        .revokeIPhoneMicrophoneOutputOnlyTransition(
                            replacementToken
                        )
                }
                guard audioLifecycle
                    .reuseIPhoneMicrophoneOutputOnlyTransition(
                        executingToken,
                        ownerEpoch: expectedSessionGeneration
                    ) else {
                    return nil
                }
                microphoneOutputOnlyToken = executingToken
                return executingToken
            }

            if let selectedToken = retirementContext.selectedToken {
                switch selectedToken.state {
                case .executing, .succeeded, .failed:
                    if let replacementToken,
                       replacementToken !== selectedToken {
                        audioLifecycle
                            .revokeIPhoneMicrophoneOutputOnlyTransition(
                                replacementToken
                            )
                    }
                    guard audioLifecycle
                        .reuseIPhoneMicrophoneOutputOnlyTransition(
                            selectedToken,
                            ownerEpoch: expectedSessionGeneration
                        ) else {
                        return nil
                    }
                    microphoneOutputOnlyToken = selectedToken
                    return selectedToken

                case .armed:
                    audioLifecycle
                        .revokeIPhoneMicrophoneOutputOnlyTransition(
                            selectedToken
                        )
                    if selectedToken.state == .executing {
                        continue
                    }
                    _ = retirementContext
                        .clearSelectedTokenIfRevoked(
                            selectedToken
                        )
                    continue

                case .revoked:
                    _ = retirementContext
                        .clearSelectedTokenIfRevoked(
                            selectedToken
                        )
                    continue
                }
            }

            if replacementToken == nil {
                replacementToken =
                    audioLifecycle
                        .beginIPhoneMicrophoneOutputOnlyTransition(
                            ownerEpoch: expectedSessionGeneration
                        )
            }
            guard let candidate = replacementToken else {
                return nil
            }
            let selectedToken =
                retirementContext.selectToken(candidate)
            if selectedToken === candidate {
                microphoneOutputOnlyToken = candidate
                return candidate
            }
        }
    }

    #if DEBUG
    func debugPrepareIPhoneMicrophoneForTransportSuspensionForTests(
        peer expectedPeer: WebRTCPeer
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        let retirementContext =
            WebRTCIOSMicrophoneRetirementContext(
                startSequence: 0,
                retiringAuthorizationIdentity: nil
            )
        return prepareIPhoneMicrophoneForTransportSuspension(
            retirementContext: retirementContext,
            expectedPeerIdentity: ObjectIdentifier(expectedPeer),
            expectedSessionGeneration: sessionGeneration
        )
    }
    #endif

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

    static func rendezvousEndpoint(
        debugOverride: String?,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL? {
        #if DEBUG
        if let debugOverride,
           let endpoint = validEndpoint(debugOverride) {
            return endpoint
        }
        #endif

        guard let configured = infoDictionary["OpensteamerRendezvousURL"] as? String else {
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
