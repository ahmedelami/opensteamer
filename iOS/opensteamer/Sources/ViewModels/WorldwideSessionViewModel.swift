import AudioToolbox
import AVFoundation
import CoreGraphics
import Foundation
import RemoteSessionCore
import UIKit
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

/// Exact viewer geometry and ownership under which one focused-window resize interaction exists.
/// A target is never allowed to cross any member of this binding.
struct FocusedWindowResizeBinding: Equatable {
    let lease: WorldwideScreenPresentationLease
    let inputSessionID: UUID
    let screenRequestID: UInt64
    let trackIdentity: ObjectIdentifier
    let containerSize: CGSize
    let viewerVideoSize: CGSize
}

enum FocusedWindowResizePendingOperation: Equatable {
    case targetRequest(operationID: UUID, focusGeneration: UInt64?)
    case selection(operationID: UUID, focusGeneration: UInt64?)
    case commit(
        operationID: UUID,
        consumedTargetGeneration: UUID,
        focusGeneration: UInt64?
    )

    var operationID: UUID {
        switch self {
        case .targetRequest(let operationID, _),
             .selection(let operationID, _),
             .commit(let operationID, _, _):
            operationID
        }
    }

    var focusGeneration: UInt64? {
        switch self {
        case .targetRequest(_, let focusGeneration),
             .selection(_, let focusGeneration),
             .commit(_, _, let focusGeneration):
            focusGeneration
        }
    }

    func matches(_ action: WebRTCInputAction) -> Bool {
        switch (self, action) {
        case (.targetRequest, .requestFocusedWindowResizeTarget),
             (.selection, .selectWindowForResize):
            true
        case (.commit(_, let consumedGeneration, _),
              .commitFocusedWindowResize(let actionGeneration, _, _)):
            consumedGeneration == actionGeneration
        default:
            false
        }
    }
}

struct FocusedWindowResizeInteraction: Equatable {
    let id: UUID
    let binding: FocusedWindowResizeBinding
    var target: WebRTCWindowResizeTarget?
    var pending: FocusedWindowResizePendingOperation?
}

enum FocusedWindowResizeState: Equatable {
    case inactive
    case active(FocusedWindowResizeInteraction)

    var interaction: FocusedWindowResizeInteraction? {
        guard case .active(let interaction) = self else { return nil }
        return interaction
    }

    var isActive: Bool { interaction != nil }
}

/// Composite identity for an in-flight show/hide request across reconnect generations.
struct WorldwideScreenVisibilityRequestKey: Hashable, Sendable {
    let sessionGeneration: UUID
    let requestID: UInt64
}

/// SwiftUI-facing projection of the native renderer fence for one exact screen lease.
/// The renderer remains mounted while `forceCover` is true so covered marker/real frames can still
/// reach Metal and satisfy the negotiated resume proof without becoming visible.
struct WorldwideScreenMediaViewerFence: Equatable, Sendable {
    let lease: WorldwideScreenPresentationLease
    let coverID: UUID
    let forceCover: Bool
    let minimumAcceptedRTPTimestamp: UInt32?
    let proofRTPTimestamps: Set<UInt32>
    let markerProof: ScreenVideoInBandMarkerNonce?
    let proofRequestRevision: UInt64
    let statusText: String?
}

/// Exact authority to reveal a privacy cover retained across one transport recovery. A later
/// suspension on the same screen lease necessarily owns a different cover identity and must not
/// be exposed by a delayed frame from the preceding recovery.
private struct WorldwideScreenPresentationRecoveryRevealFence: Equatable {
    let lease: WorldwideScreenPresentationLease
    let coverID: UUID
    let proofRequestRevision: UInt64

    init(_ fence: WorldwideScreenMediaViewerFence) {
        lease = fence.lease
        coverID = fence.coverID
        proofRequestRevision = fence.proofRequestRevision
    }

    func matches(_ fence: WorldwideScreenMediaViewerFence?) -> Bool {
        guard let fence else { return false }
        return fence.lease == lease
            && fence.coverID == coverID
            && fence.proofRequestRevision == proofRequestRevision
    }
}

struct WorldwideScreenMediaPrimarySource: Equatable, Sendable {
    let receiverID: String
    let sourceID: UInt32
    let rtpTimestamp: UInt32
}

enum WorldwideScreenMediaGeometryChangeDisposition: Equatable, Sendable {
    case localFloorInvalidation
    case unchanged
    case mutation
}

/// Pure validation shared by the MainActor integration and focused iOS tests. No wall clock or
/// encoder-domain timestamp is accepted at this receiver boundary.
enum WorldwideScreenMediaViewerProofPolicy {
    static func geometryChangeDisposition(
        _ size: CGSize,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> WorldwideScreenMediaGeometryChangeDisposition {
        if size == .zero { return .localFloorInvalidation }
        guard size.width.isFinite,
              size.height.isFinite,
              Int(size.width.rounded()) == expectedWidth,
              Int(size.height.rounded()) == expectedHeight else {
            return .mutation
        }
        return .unchanged
    }

    static func coveredRetryFence(
        from current: WorldwideScreenMediaViewerFence,
        proofRequestRevision: UInt64
    ) -> WorldwideScreenMediaViewerFence {
        WorldwideScreenMediaViewerFence(
            lease: current.lease,
            coverID: current.coverID,
            forceCover: true,
            minimumAcceptedRTPTimestamp: nil,
            proofRTPTimestamps: [],
            markerProof: nil,
            proofRequestRevision: proofRequestRevision,
            statusText: "Resuming screen…"
        )
    }

    static func isSameSuspensionRetry(
        _ ready: WebRTCScreenMediaMarkerReady,
        replacing currentAttemptID: UUID?,
        notice: WebRTCScreenMediaSuspensionNotice
    ) -> Bool {
        guard let currentAttemptID else { return false }
        return ready.belongs(to: notice)
            && ready.attemptID != currentAttemptID
    }

    static func exactPrimarySource(
        in snapshot: WebRTCRemoteVideoSourceSnapshot
    ) -> WorldwideScreenMediaPrimarySource? {
        guard !snapshot.receiverID.isEmpty,
              snapshot.sourceIDs.count == 1,
              snapshot.rtpTimestamps.count == 1,
              let sourceID = snapshot.sourceIDs.first,
              sourceID > 0,
              let rtpTimestamp = snapshot.rtpTimestamps.first else {
            return nil
        }
        return WorldwideScreenMediaPrimarySource(
            receiverID: snapshot.receiverID,
            sourceID: sourceID,
            rtpTimestamp: rtpTimestamp
        )
    }

    static func acceptsMarkerProof(
        _ observation: WebRTCVideoMarkerPresentationProofObservation,
        expectedMarker: ScreenVideoInBandMarkerNonce,
        geometry: WebRTCScreenMediaGeometry,
        baseline: WorldwideScreenMediaPrimarySource?,
        current: WorldwideScreenMediaPrimarySource
    ) -> Bool {
        guard observation.marker == expectedMarker,
              geometry.isCompatiblePresentation(
                width: observation.width,
                height: observation.height
              ),
              current.rtpTimestamp == observation.rtpTimestamp else {
            return false
        }
        guard let baseline else { return true }
        return baseline.receiverID == current.receiverID
            && baseline.sourceID == current.sourceID
            && WebRTCRTPSerialComparator.isStrictlyNewer(
                observation.rtpTimestamp,
                than: baseline.rtpTimestamp
            )
    }

    static func acceptsRealCandidate(
        rtpTimestamp: UInt32,
        width: Int,
        height: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        minimumRTPTimestamp: UInt32,
        receiverID: String,
        sourceID: UInt32,
        current: WorldwideScreenMediaPrimarySource
    ) -> Bool {
        width == expectedWidth
            && height == expectedHeight
            && receiverID == current.receiverID
            && sourceID == current.sourceID
            && current.rtpTimestamp == rtpTimestamp
            && WebRTCRTPSerialComparator.isSameOrNewer(
                rtpTimestamp,
                than: minimumRTPTimestamp
            )
    }

    static func resumedAcknowledgementMatches(
        _ acknowledgement: WebRTCScreenMediaResumedAcknowledgement,
        requestID: UInt64,
        presentation: WebRTCScreenMediaPresentation,
        screenRequestID: UInt64,
        inputAuthorizationIsValid: Bool
    ) -> Bool {
        acknowledgement.isValid
            && acknowledgement.request.id == requestID
            && acknowledgement.request.presentation == presentation
            && (
                acknowledgement.inputCapability == nil
                    || acknowledgement.inputCapability?.screenRequestID
                        == screenRequestID
            )
            && (
                acknowledgement.inputCapability == nil
                    || inputAuthorizationIsValid
            )
    }
}

private enum WorldwideScreenMediaViewerPhase: Equatable {
    case awaitingCoverInstallation
    case sendingCoveredAcknowledgementAndHide
    case awaitingHideAcknowledgement
    case awaitingMarkerReady
    case awaitingMarkerPresentation
    case sendingMarkerPresentation
    case awaitingResumeReady
    case awaitingRealPresentation
    case sendingResumeRequest
    case awaitingResumedAcknowledgement
    case resumed
}

private final class WorldwideScreenMediaViewerAttempt {
    let id = UUID()
    let notice: WebRTCScreenMediaSuspensionNotice
    let lease: WorldwideScreenPresentationLease
    let sessionGeneration: UUID
    let expectedPeer: WebRTCPeer
    let expectedTrack: WebRTCRemoteVideoTrack
    let expectedTrackIdentity: ObjectIdentifier
    let baselineSourceSnapshot: WebRTCRemoteVideoSourceSnapshot
    var phase: WorldwideScreenMediaViewerPhase = .awaitingCoverInstallation
    var hideRequestKey: WorldwideScreenVisibilityRequestKey?
    var markerReady: WebRTCScreenMediaMarkerReady?
    var markerPresentation: WebRTCScreenMediaMarkerPresentation?
    var resumeReady: WebRTCScreenMediaResumeReady?
    var resumePresentation: WebRTCScreenMediaPresentation?
    var resumeRequestID: UInt64?
    var receiverID: String?
    var sourceID: UInt32?
    var presentedWidth: Int?
    var presentedHeight: Int?
    var armedProofRTPTimestamp: UInt32?
    var minimumAcceptedRTPTimestamp: UInt32?
    var proofRequestRevision: UInt64 = 0
    var earlyResumedAcknowledgement: (
        acknowledgement: WebRTCScreenMediaResumedAcknowledgement,
        authorization: WebRTCInputAuthorization?
    )?

    init(
        notice: WebRTCScreenMediaSuspensionNotice,
        lease: WorldwideScreenPresentationLease,
        sessionGeneration: UUID,
        expectedPeer: WebRTCPeer,
        expectedTrack: WebRTCRemoteVideoTrack
    ) {
        self.notice = notice
        self.lease = lease
        self.sessionGeneration = sessionGeneration
        self.expectedPeer = expectedPeer
        self.expectedTrack = expectedTrack
        expectedTrackIdentity = ObjectIdentifier(expectedTrack)
        baselineSourceSnapshot = expectedTrack.sourceSnapshot()
    }
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
    let recoveringLease: WorldwideScreenPresentationLease?
    let activeScreenRequestID: UInt64?
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
    /// Exact reducer operation and pre-staged native capability for transaction-owned recovery.
    /// Nil preserves the legacy/test-only proof path for initial non-recovery observation.
    let recoveryTransaction: WorldwideAudioRecoveryTransaction?
    var stage: IOSPlayoutProofStage
    var recoveryAuthorization: WebRTCIOSPlayoutRecoveryAuthorization?
    var nativeRecoveryReceiptWasConsumed = false
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
        recoveryTransaction: WorldwideAudioRecoveryTransaction? = nil,
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
        self.recoveryTransaction = recoveryTransaction
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
    private static let peerRetirementFailureMessage =
        "The previous iPhone audio session could not be retired safely. Restart opensteamer before reconnecting."
    private static let peerRetirementInProgressMessage =
        "The previous iPhone audio session is still retiring. Try reconnecting in a moment."
    /// Never outrun the host's 60 Hz scroll budget during a sustained gesture.
    static let remoteScrollFlushInterval: Duration = .milliseconds(17)

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
    @Published private(set) var isScreenVisible = false {
        didSet {
            guard oldValue != isScreenVisible else { return }
            advanceScreenLivenessGeneration(clearRenderObservation: true)
        }
    }
    @Published private var recoveringScreenPresentationLease:
        WorldwideScreenPresentationLease?
    @Published private(set) var remoteVideoTrack: WebRTCRemoteVideoTrack? {
        willSet {
            let currentIdentity = remoteVideoTrack.map { ObjectIdentifier($0) }
            let nextIdentity = newValue.map { ObjectIdentifier($0) }
            guard currentIdentity != nextIdentity else { return }
            cancelScreenMediaViewerSuspension(
                reason: "The remote video track changed during screen resume.",
                notifyPeer: true
            )
            remoteVideoTrackIdentityWillChange()
        }
        didSet {
            let previousIdentity = oldValue.map { ObjectIdentifier($0) }
            let currentIdentity = remoteVideoTrack.map { ObjectIdentifier($0) }
            guard previousIdentity != currentIdentity else { return }
            advanceScreenLivenessGeneration(clearRenderObservation: true)
        }
    }
    @Published private(set) var screenAcknowledgementOracle:
        WorldwideScreenAcknowledgementOracleSnapshot?
    @Published private(set) var screenMediaViewerFence:
        WorldwideScreenMediaViewerFence? {
        didSet {
            guard oldValue != screenMediaViewerFence else { return }
            if screenMediaViewerFence?.forceCover == true {
                cancelFocusedWindowResize()
            }
            if let recoveryRevealFence = screenPresentationRevealAfterRecoveryFence,
               !recoveryRevealFence.matches(screenMediaViewerFence) {
                screenPresentationRevealAfterRecoveryFence = nil
            }
            refreshScreenLivenessDiagnostic()
        }
    }
    @Published private(set) var screenLivenessDiagnosticSnapshot =
        WorldwideScreenLivenessDiagnosticSnapshot.unobserved
    @Published private(set) var screenClientDiagnosticsDeliveryText = "Idle"
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
    @Published private(set) var focusedWindowResizeState: FocusedWindowResizeState = .inactive

    private var signaling: RendezvousSignalingClient?
    private var peer: WebRTCPeer? {
        didSet {
            guard oldValue !== peer else { return }
            cancelScreenMediaViewerSuspension(
                reason: "The media peer changed during screen resume.",
                notifyPeer: oldValue != nil
            )
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
    private var rawMicrophoneMissingStatisticsTracker =
        WorldwideRawMicrophoneMissingStatisticsTracker()
    private var ordinaryPlayoutLivenessTracker =
        IOSOrdinaryPlayoutLivenessTracker()
    /// One automatic recovery per continuous fault episode. These latches deliberately survive
    /// the recovery's policy/auth rotation and reopen only after real counter advancement.
    private struct MicrophoneAutomaticRecoveryBinding: Equatable {
        let sessionGeneration: UUID
        let peerIdentity: ObjectIdentifier
        let transportAuthorizationGeneration: UUID
    }
    private struct MicrophoneTransportSuspensionBinding: Equatable {
        let sessionGeneration: UUID
        let peerIdentity: ObjectIdentifier
        let transportAuthorizationGeneration: UUID
        let microphoneOperationGeneration: UUID
        let retirementID: UUID
        let tokenID: UUID
        let operationID: UUID
    }
    private var microphoneAutomaticRecoveryConsumedBinding:
        MicrophoneAutomaticRecoveryBinding?
    /// Holds admission closed while the output-only RemoteIO recovery is still being proved.
    /// It intentionally survives the recovery's audio-policy rotation, but not a peer/session or
    /// transport-authorization boundary.
    private var microphoneAdmissionRecoveryPendingBinding:
        MicrophoneAutomaticRecoveryBinding?
    private var microphoneAdmissionRecoveryProofAttemptID: UUID?
    private var microphoneTransportSuspensionBinding:
        MicrophoneTransportSuspensionBinding?
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
    private var sessionRetirementTask: Task<Bool, Never>?
    private var sessionRetirementGeneration = UUID()
    private var peerEventTask: Task<Void, Never>?
    /// Lossless reducer receipts remain alive through native peer retirement so the terminal
    /// device barrier is consumed before a replacement peer may bind its sequence namespace.
    private var audioTransactionEventTask: Task<Bool, Never>?
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

    private enum IPhoneMicrophoneDeferredRecoveryResolution {
        case noDeferredRecovery
        case recoveryStarted
        case retryableFailure
        case reconnectRequired
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
    /// Exact view-model ownership for an asynchronous native output-only teardown. A route-loss
    /// retry queues behind this task so recovery cannot race the retiring RemoteIO write.
    private var microphoneNativeTeardownID: UUID?
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
                cancelFocusedWindowResize()
                advanceScreenLivenessGeneration(clearRenderObservation: true)
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
    private var activeRemoteScroll: ActiveRemoteScroll?
    private var remoteScrollFlushTask: Task<Void, Never>?
    private var remoteScrollSendAuthorization: WebRTCInputSendAuthorization?
    private var focusedWindowResizeSendAuthorization: WebRTCInputSendAuthorization?
    private var remoteInputLifecycleSendAuthorization:
        WebRTCInputSendAuthorization?
    private var applicationInputIsSuspended = false
    private var pendingRemoteInputs: [UInt64: PendingRemoteInput] = [:]
    private var pendingRemoteInputOrder: [UInt64] = []
    private var earlyRemoteInputFeedback: [UInt64: WebRTCInputFeedback] = [:]
    private var retiredFocusedWindowResizeRequests: [
        RetiredFocusedWindowResizeRequestKey: RetiredFocusedWindowResizeRequest
    ] = [:]
    private var retiredFocusedWindowResizeRequestKeyOrder: [
        RetiredFocusedWindowResizeRequestKey
    ] = []
    private var latestPointerIntentID: UInt64 = 0
    private var remoteInputAuthorization: WebRTCInputAuthorization?
    private var currentScreenPresentationLease: WorldwideScreenPresentationLease?
    private var activeScreenPresentationLease: WorldwideScreenPresentationLease?
    private var remoteScreenOwnerLease: WorldwideScreenPresentationLease?
    private var activeScreenRequestID: UInt64?
    private var screenLivenessClassifier = WorldwideScreenLivenessClassifier()
    private var screenLivenessGeneration: UInt64 = 1
    private var latestScreenVideoRenderObservation:
        WebRTCVideoRenderObservation?
    private var latestScreenVideoPresentationUptimeNanoseconds: UInt64?
    private var nextScreenClientDiagnosticsSequence: UInt64 = 1
    private var screenMediaViewerAttempt: WorldwideScreenMediaViewerAttempt?
    private var screenMediaCoveredHideTask: Task<Void, Never>?
    private var screenMediaMarkerPresentationTask: Task<Void, Never>?
    private var screenMediaMarkerPresentationTaskID: UUID?
    private var screenMediaResumeRequestTask: Task<Void, Never>?
    private var screenMediaResumeRequestTaskID: UUID?
    private var screenTeardownOperationByLeaseID: [UUID: UUID] = [:]
    private var screenShowOperationByLeaseID: [UUID: UUID] = [:]
    private var screenVisibilityQueue: [QueuedScreenVisibilityOperation] = []
    private var screenVisibilityDrainTask: Task<Void, Never>?
    private var screenPresentationRecoveryTask: Task<Void, Never>?
    private var screenPresentationRecoveryAttemptID: UUID?
    private var screenPresentationRevealAfterRecoveryFence:
        WorldwideScreenPresentationRecoveryRevealFence?
    private var screenVisibilityQueueGeneration = UUID()
    private var acceptsActiveScreenAcknowledgement = false
    private var remoteHideRequired = false
    private var screenVisibilityOperationGeneration = UUID()
    #if DEBUG
    private var debugFocusedWindowResizeTrackOwner: NSObject?
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
    private var debugRawMicrophoneMissingStatisticsUptimeClock:
        (@MainActor () -> TimeInterval)?
    private var debugStalledIPhoneMicrophoneRecoveryObserver:
        (@MainActor () -> Void)?
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
            WebRTCInputVideoSize?,
            WebRTCInputCapability,
            WebRTCInputAuthorization,
            WebRTCInputSendAuthorization?
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
    private var debugScreenMediaCancellationObserver:
        (@MainActor (WebRTCPeer, String) -> Void)?
    private var debugScreenLivenessUptimeClock:
        (@MainActor () -> UInt64)?
    #endif

    init(audioLifecycle: WorldwideAudioLifecycleController = WorldwideAudioLifecycleController()) {
        self.audioLifecycle = audioLifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
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
        #if DEBUG
        // Production recovery is dispatched only through the transaction callback installed after
        // the exact native device namespace binds. This legacy callback remains a test seam for
        // controller fixtures that intentionally do not install a native transaction stream.
        audioLifecycle.onPlaybackRecoveryRequested = { [weak self] in
            guard let self,
                  self.debugIOSPlayoutRecoveryRequester != nil else {
                return
            }
            self.beginIOSPlayoutProof(
                requestRecovery: true,
                postCallRecoveryMilestone:
                    self.audioLifecycle
                        .postCallMicrophoneRecoveryMilestone
            )
        }
        #endif
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

    deinit {
        audioTransactionEventTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Published capabilities

    var hasActiveSession: Bool {
        signaling != nil || peer != nil || sessionTask != nil
    }

    var canViewScreen: Bool {
        isPeerConnected && iceIsConnected && isControlChannelReady
    }

    var screenLivenessStatusText: String {
        screenLivenessDiagnosticSnapshot.statusText
    }

    var isRemoteInputAvailable: Bool {
        remoteInputCapability != nil
            && remoteInputAuthorization?.isValid == true
            && isScreenVisible
            && canViewScreen
            && applicationAllowsRemoteInput
    }

    private var applicationAllowsRemoteInput: Bool {
        guard !applicationInputIsSuspended else { return false }
        return switch lastHandledApplicationLifecyclePhase {
        case .inactive, .background:
            false
        case .active, nil:
            true
        }
    }

    var isRemotePrimaryDragAvailable: Bool {
        isRemoteInputAvailable && remoteInputCapability?.supportsPrimaryDrag == true
    }

    var isRemoteScrollAvailable: Bool {
        isRemoteInputAvailable && remoteInputCapability?.supportsScroll == true
    }

    var isFocusedWindowResizeAvailable: Bool {
        isRemoteInputAvailable
            && remoteInputCapability?.supportsFocusedWindowResize == true
    }

    var canResumeAudioPlayback: Bool {
        hasActiveSession
            && !audioLifecycle.audioRecoveryRequiresSessionReconnect
            && (audioRequiresExplicitResume || audioStateText == "Playback unavailable")
    }

    var audioRecoveryButtonTitle: String {
        audioStateText == "Playback unavailable" ? "Retry Audio" : "Resume Audio"
    }

    var canToggleIPhoneMicrophone: Bool {
        hasActiveSession
            && peer != nil
            && !isMicrophoneAdmissionCleanupInProgress
            && !audioLifecycle.audioRecoveryRequiresSessionReconnect
    }

    var iPhoneMicrophoneButtonTitle: String {
        if audioLifecycle.audioRecoveryRequiresSessionReconnect {
            return "iPhone Microphone Unavailable"
        }
        if microphoneAdmissionFailedSessionGeneration == sessionGeneration
            || (microphoneIntentEnabled
                && !isMicrophoneSending
                && audioLifecycle
                    .microphoneWaitsForDeferredAudioRecovery
                && audioError != nil) {
            return "Retry iPhone Microphone"
        }
        if microphoneIntentEnabled,
           !microphoneIsBlockedByCall,
           audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            return "Cancel Microphone Recovery"
        }
        if microphoneIntentEnabled,
           !microphoneIsBlockedByCall,
           audioLifecycle.microphoneRequiresExplicitResume {
            return "Resume iPhone Microphone"
        }
        return microphoneIntentEnabled
            ? "Turn Off iPhone Microphone"
            : "Use iPhone Microphone"
    }

    var iPhoneMicrophoneButtonSystemImage: String {
        if audioLifecycle.audioRecoveryRequiresSessionReconnect {
            return "mic.slash.fill"
        }
        if microphoneAdmissionFailedSessionGeneration == sessionGeneration
            || (microphoneIntentEnabled
                && !isMicrophoneSending
                && audioLifecycle
                    .microphoneWaitsForDeferredAudioRecovery
                && audioError != nil)
            || (microphoneIntentEnabled
                && !microphoneIsBlockedByCall
                && audioLifecycle.microphoneRequiresExplicitResume) {
            return "arrow.clockwise"
        }
        if microphoneIntentEnabled,
           !microphoneIsBlockedByCall,
           audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            return "xmark.circle.fill"
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
        if sessionRetirementTask == nil,
           let retirementError = Self
            .iOSPeerRetirementAdmissionErrorMessage() {
            stateText = "Connection failed"
            lastError = retirementError
            return false
        }

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
        microphoneAutomaticRecoveryConsumedBinding = nil
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
        microphoneTransportSuspensionBinding = nil
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
                let retirementSucceeded = await pendingRetirement.value
                guard let self,
                      !Task.isCancelled,
                      sessionGeneration == generation,
                      signaling != nil else { return }
                guard retirementSucceeded else {
                    failSession(
                        Self.peerRetirementFailureMessage,
                        generation: generation
                    )
                    return
                }
                if sessionRetirementGeneration == retirementGeneration {
                    sessionRetirementTask = nil
                }
                if let retirementError = Self
                    .iOSPeerRetirementAdmissionErrorMessage() {
                    failSession(
                        retirementError,
                        generation: generation
                    )
                    return
                }
                audioLifecycle.prepare(serverName: remoteDisplayName)
                await runSession(client: client, generation: generation)
            }
        } else {
            if let retirementError = Self
                .iOSPeerRetirementAdmissionErrorMessage() {
                failSession(
                    retirementError,
                    generation: generation
                )
                return true
            }
            audioLifecycle.prepare(serverName: remoteDisplayName)
            sessionTask = Task { [weak self] in
                await self?.runSession(client: client, generation: generation)
            }
        }
        return true
    }

    private static func iOSPeerRetirementAdmissionErrorMessage()
        -> String? {
        switch WebRTCPeer
            .iOSAudioDeviceRetirementAdmissionState() {
        case .available:
            return nil
        case .retirementInProgress:
            return peerRetirementInProgressMessage
        case .failed:
            return peerRetirementFailureMessage
        }
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

    /// Admits bootstrap/availability only after this process no longer owns media and the exact
    /// preceding peer/signaling retirement has finished. This gate must run before availability
    /// connects because the host may treat a new ready exchange as replacement authority.
    func admitFreshConnectionPreparation() async -> Bool {
        guard !hasActiveSession,
              !isConnecting,
              recoveringScreenPresentationLease == nil else {
            return false
        }
        if sessionRetirementTask == nil,
           let retirementError = Self
            .iOSPeerRetirementAdmissionErrorMessage() {
            stateText = "Connection failed"
            lastError = retirementError
            return false
        }

        let expectedSessionGeneration = sessionGeneration
        if let pendingRetirement = sessionRetirementTask {
            let expectedRetirementGeneration = sessionRetirementGeneration
            let retirementSucceeded = await pendingRetirement.value
            guard retirementSucceeded else {
                stateText = "Connection failed"
                lastError = Self.peerRetirementFailureMessage
                return false
            }
            guard !Task.isCancelled,
                  sessionGeneration == expectedSessionGeneration,
                  !hasActiveSession,
                  !isConnecting,
                  recoveringScreenPresentationLease == nil else {
                return false
            }
            if sessionRetirementGeneration == expectedRetirementGeneration {
                sessionRetirementTask = nil
            }
        }

        if let retirementError = Self
            .iOSPeerRetirementAdmissionErrorMessage() {
            stateText = "Connection failed"
            lastError = retirementError
            return false
        }
        return !Task.isCancelled
            && sessionGeneration == expectedSessionGeneration
            && !hasActiveSession
            && !isConnecting
            && recoveringScreenPresentationLease == nil
    }

    /// Keeps authenticated audio playout alive while independently closing the screen/input
    /// presentation boundary for privacy.
    func handleAppBecameActive() {
        guard lastHandledApplicationLifecyclePhase != .active else {
            return
        }
        applicationInputIsSuspended = false
        lastHandledApplicationLifecyclePhase = .active
        applicationIsActive = true
        refreshScreenLivenessDiagnostic()
        recoverPassiveAudioLifecyclePreservingEstablishedMicrophone {
            establishedMicrophoneAuthorization in
            audioLifecycle.appBecameActive(
                preservingEstablishedMicrophoneAuthorization:
                    establishedMicrophoneAuthorization
            )
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
        // `.inactive` is also used for short system interruptions while the viewer remains the
        // logical foreground presentation. Keep the authenticated screen owner alive; SwiftUI
        // covers its renderer and gates input until the scene is active again.
        suspendRemoteInputForApplicationLifecycle()
        refreshScreenLivenessDiagnostic()
    }

    func handleAppEnteredBackground() {
        guard lastHandledApplicationLifecyclePhase != .background else {
            return
        }
        lastHandledApplicationLifecyclePhase = .background
        applicationIsActive = false
        suspendRemoteInputForApplicationLifecycle()
        pausePendingIPhoneMicrophoneForInactiveApp()
        recoverPassiveAudioLifecyclePreservingEstablishedMicrophone {
            establishedMicrophoneAuthorization in
            audioLifecycle.appEnteredBackground(
                preservingEstablishedMicrophoneAuthorization:
                    establishedMicrophoneAuthorization
            )
        }
        hideScreenForPassiveLifecycleIfNeeded()
    }

    @objc private func applicationWillResignActive() {
        suspendRemoteInputForApplicationLifecycle()
    }

    @objc private func applicationDidBecomeActive() {
        applicationInputIsSuspended = false
    }

    private func recoverPassiveAudioLifecyclePreservingEstablishedMicrophone(
        _ recovery: (WebRTCIOSMicrophoneAuthorization?) -> Bool
    ) {
        let authorization = microphoneAuthorization
        let establishedMicrophoneAuthorization =
            isMicrophoneSending && authorization?.isValid == true
                ? authorization
                : nil
        preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation =
            establishedMicrophoneAuthorization != nil
        defer {
            preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation = false
        }
        let recoveryWasDispatched = recovery(
            establishedMicrophoneAuthorization
        )
        if establishedMicrophoneAuthorization != nil,
           !recoveryWasDispatched {
            // The preservation privilege covers only the atomic A-to-B handoff. If A could not
            // retire/drain or B could not stage, immediately restore ordinary fail-closed mic
            // teardown rather than leaving a live carrier outside reducer ownership.
            preservesEstablishedMicrophoneAcrossNextPassiveProofInvalidation = false
            suspendIPhoneMicrophone(
                stateText: "Paused — audio recovery required",
                preserveIntent: true,
                reprovePlayout: false
            )
        }
    }

    private func pausePendingIPhoneMicrophoneForInactiveApp() {
        guard !isMicrophoneSending else { return }

        if microphoneAdmissionRecoveryPendingBinding
            == currentMicrophoneAutomaticRecoveryBinding() {
            microphoneAdmissionRecoveryPendingBinding = nil
            microphoneAdmissionRecoveryProofAttemptID = nil
            microphoneAdmissionFailedSessionGeneration =
                sessionGeneration
            microphoneError =
                "Automatic microphone recovery was interrupted. Tap Retry iPhone Microphone."
        }

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
        recoverPassiveAudioLifecyclePreservingEstablishedMicrophone {
            establishedMicrophoneAuthorization in
            audioLifecycle.resumePlayback(
                preservingEstablishedMicrophoneAuthorization:
                    establishedMicrophoneAuthorization
            )
        }
    }

    func toggleIPhoneMicrophone() {
        guard !isMicrophoneAdmissionCleanupInProgress else { return }

        if microphoneAdmissionFailedSessionGeneration == sessionGeneration {
            let retriesDeferredAudioRecovery =
                audioLifecycle
                    .microphoneWaitsForDeferredAudioRecovery
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphoneAutomaticRecoveryConsumedBinding = nil
            microphoneAdmissionRecoveryPendingBinding = nil
            microphoneAdmissionRecoveryProofAttemptID = nil
            rawMicrophoneContinuityTracker.reset()
            microphoneError = nil
            if retriesDeferredAudioRecovery {
                microphoneStateText = "Recovering audio"
                if audioLifecycle.snapshot.requiresExplicitResume {
                    switch beginExplicitIPhoneMicrophoneResumeIfNeeded() {
                    case .waiting:
                        return
                    case .notRequired, .ready:
                        continueIPhoneMicrophoneEnablementIfPossible()
                    }
                } else {
                    resumeAudioPlayback()
                }
                return
            }
            microphoneStateText = "Starting"
            switch beginExplicitIPhoneMicrophoneResumeIfNeeded() {
            case .waiting:
                return
            case .notRequired, .ready:
                continueIPhoneMicrophoneEnablementIfPossible()
            }
            return
        }

        if microphoneIntentEnabled,
           !isMicrophoneSending,
           audioLifecycle.microphoneWaitsForDeferredAudioRecovery,
           audioError != nil {
            microphoneError = nil
            microphoneStateText = "Recovering audio"
            if audioLifecycle.snapshot.requiresExplicitResume {
                switch beginExplicitIPhoneMicrophoneResumeIfNeeded() {
                case .waiting:
                    return
                case .notRequired, .ready:
                    continueIPhoneMicrophoneEnablementIfPossible()
                }
            } else {
                resumeAudioPlayback()
            }
            return
        }

        if microphoneIntentEnabled,
           !isMicrophoneSending,
           audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            manuallyDisabledMicrophoneSessionGeneration = sessionGeneration
            automaticMicrophoneAttemptedSessionGeneration = sessionGeneration
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphoneAutomaticRecoveryConsumedBinding = nil
            microphoneAdmissionRecoveryPendingBinding = nil
            microphoneAdmissionRecoveryProofAttemptID = nil
            rawMicrophoneContinuityTracker.reset()
            microphoneError = nil
            audioLifecycle.cancelPendingMicrophoneInputResume()
            suspendIPhoneMicrophone(
                stateText: "Off",
                preserveIntent: false,
                reprovePlayout: false
            )
            return
        }

        if microphoneIntentEnabled,
           !isMicrophoneSending,
           audioLifecycle.microphoneRequiresExplicitResume {
            switch beginExplicitIPhoneMicrophoneResumeIfNeeded() {
            case .waiting:
                return
            case .notRequired, .ready:
                continueIPhoneMicrophoneEnablementIfPossible()
                return
            }
        }

        if microphoneIntentEnabled {
            manuallyDisabledMicrophoneSessionGeneration = sessionGeneration
            automaticMicrophoneAttemptedSessionGeneration = sessionGeneration
            microphoneAdmissionFailedSessionGeneration = nil
            microphoneAdmissionDeferredUntilTransportProof = nil
            microphoneAutomaticRecoveryConsumedBinding = nil
            microphoneAdmissionRecoveryPendingBinding = nil
            microphoneAdmissionRecoveryProofAttemptID = nil
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
        microphoneAutomaticRecoveryConsumedBinding = nil
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
        rawMicrophoneContinuityTracker.reset()
        microphoneError = nil
        switch beginExplicitIPhoneMicrophoneResumeIfNeeded() {
        case .waiting:
            return
        case .notRequired, .ready:
            continueIPhoneMicrophoneEnablementIfPossible()
        }
    }

    private enum ExplicitMicrophoneResumeResult {
        case notRequired
        case waiting
        case ready
    }

    /// Uses the microphone control as the explicit input-only recovery action after a private
    /// output route disappears. A synchronous recovery can continue directly into admission;
    /// transaction-backed recovery returns here and the lifecycle snapshot resumes admission.
    private func beginExplicitIPhoneMicrophoneResumeIfNeeded()
        -> ExplicitMicrophoneResumeResult {
        guard audioLifecycle.snapshot.requiresExplicitResume else {
            return .notRequired
        }
        guard !microphoneIsBlockedByCall else {
            microphoneStateText = microphoneActivationBlockedStateText
            return .waiting
        }
        if audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            microphoneStateText = "Recovering microphone"
            return .waiting
        }
        guard audioLifecycle.microphoneRequiresExplicitResume else {
            return audioLifecycle.microphoneActivationIsAllowed()
                ? .ready
                : .waiting
        }

        microphoneStateText = "Recovering microphone"
        microphoneError = nil
        let recoveryWasDispatched =
            audioLifecycle.resumeMicrophoneInput(
                deferRecoveryUntilNativeTeardownCompletes:
                    microphoneNativeTeardownID != nil
            )
        if audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            return .waiting
        }
        guard recoveryWasDispatched,
              audioLifecycle.microphoneActivationIsAllowed() else {
            microphoneStateText = microphoneActivationBlockedStateText
            return .waiting
        }
        return .ready
    }

    private var microphoneActivationBlockedStateText: String {
        if microphoneIsBlockedByCall {
            return "Muted — iPhone call active"
        }
        if audioLifecycle.isMicrophoneResumeRecoveryInProgress {
            return "Recovering microphone"
        }
        if audioLifecycle.microphoneRequiresExplicitResume {
            return "Paused — resume iPhone microphone"
        }
        return "Paused — audio unavailable"
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
            microphoneStateText = microphoneActivationBlockedStateText
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
                self.microphoneStateText =
                    self.microphoneActivationBlockedStateText
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
        let effectiveAudioSnapshot =
            audioSnapshot ?? audioLifecycle.snapshot
        if effectiveAudioSnapshot.errorText != nil {
            if microphoneAuthorization != nil {
                suspendIPhoneMicrophone(
                    stateText: "Paused — audio unavailable",
                    preserveIntent: true,
                    reprovePlayout: false
                )
            } else if microphoneIntentEnabled {
                microphoneStateText =
                    microphoneAdmissionFailedSessionGeneration
                        == sessionGeneration
                        ? "Unavailable"
                        : "Paused — audio unavailable"
            }
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
            microphoneStateText = microphoneActivationBlockedStateText
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
        if let pendingBinding =
            microphoneAdmissionRecoveryPendingBinding {
            if pendingBinding
                == currentMicrophoneAutomaticRecoveryBinding() {
                microphoneStateText = "Recovering audio"
                return
            }
            microphoneAdmissionRecoveryPendingBinding = nil
            microphoneAdmissionRecoveryProofAttemptID = nil
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
        guard audioLifecycle.hasBoundIOSAudioTransactionDevice else {
            microphoneStateText = "Paused — waiting for audio policy"
            return
        }

        let operationGeneration = UUID()
        let expectedSessionGeneration = sessionGeneration
        let expectedTransportAuthorizationGeneration =
            transportAuthorizationGeneration
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
        let topologyGeneration =
            audioLifecycle.beginMicrophoneTopologyTransition(
                isEnabled: true
            )
        let topologyTransactionWasBound = topologyGeneration != 0
            && audioLifecycle.bindCurrentMicrophoneTopologyTransaction(
                to: authorization,
                generation: topologyGeneration
            )
        guard topologyTransactionWasBound else {
            authorization.revoke()
            if topologyGeneration != 0 {
                _ = audioLifecycle
                    .abortCurrentMicrophoneTopologyTransition(
                        generation: topologyGeneration
                    )
            }
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
                let stageFailureReason:
                    WebRTCIOSMicrophoneStageFailureReason?
                if case let WebRTCTransportError
                    .iPhoneMicrophoneStageFailed(reason, _) = error {
                    stageFailureReason = reason
                } else {
                    stageFailureReason = nil
                }
                let shouldRecoverNativeStage =
                    stageFailureReason?
                        .permitsAutomaticAudioRecovery == true
                let stageFailureIsLifecycleControlled =
                    stageFailureReason?.isLifecycleControlled == true
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
                let nativeTeardownSucceeded =
                    await self.performIPhoneMicrophoneDisable(
                    on: expectedPeer,
                    authorization: authorization,
                    outputOnlyToken: outputOnlyToken
                )
                guard microphoneAdmissionCleanupID == cleanupID else {
                    return
                }
                guard microphoneOperationGeneration == operationGeneration,
                      sessionGeneration == expectedSessionGeneration,
                      peer === expectedPeer,
                      microphoneAuthorization == nil else {
                    _ = transferTerminalIPhoneMicrophoneOutputOnlyCompletion(
                        outputOnlyToken,
                        nativeTeardownSucceeded:
                            nativeTeardownSucceeded,
                        expectedPeer: expectedPeer,
                        expectedSessionGeneration:
                            expectedSessionGeneration
                    )
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    reconcileIPhoneMicrophone()
                    return
                }
                guard nativeTeardownSucceeded,
                      outputOnlyToken?.state == .succeeded else {
                    audioLifecycle.cancelPendingMicrophoneInputResume()
                    if let outputOnlyToken,
                       audioLifecycle
                        .abandonCurrentOutputOnlyTransitionRequiringReconnect(
                            outputOnlyToken
                        ),
                       microphoneOutputOnlyToken === outputOnlyToken {
                        microphoneOutputOnlyToken = nil
                    }
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone could not finish resetting. Reconnect this session to restore it."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                }
                let outputOnlyCompletion =
                    clearIPhoneMicrophoneOutputOnlyToken(
                        outputOnlyToken
                    )
                switch resolveIPhoneMicrophoneDeferredRecovery(
                    outputOnlyCompletion,
                    after: outputOnlyToken
                ) {
                case .recoveryStarted:
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                case .retryableFailure:
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone audio path could not recover automatically. Tap Retry iPhone Microphone."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                case .reconnectRequired:
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone audio path could not recover automatically. Reconnect this session to restore it."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                case .noDeferredRecovery:
                    break
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
                } else if shouldRecoverNativeStage {
                    microphoneStateText = "Recovering audio"
                    microphoneError = nil
                } else if stageFailureIsLifecycleControlled {
                    microphoneStateText =
                        "Paused — audio unavailable"
                } else {
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                }
                if shouldRecoverNativeStage {
                    recoverFromRetryableIPhoneMicrophoneAdmissionFailure(
                        generation: expectedSessionGeneration,
                        sourcePeer: expectedPeer,
                        transportAuthorizationGeneration:
                            expectedTransportAuthorizationGeneration,
                        operationGeneration: operationGeneration
                    )
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                }
                if stageFailureIsLifecycleControlled {
                    _ = audioLifecycle
                        .requestTransactionalRuntimePlayoutRecovery(
                            requiresRemoteAudio: false
                        )
                }
                finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
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
                let cleanupID = UUID()
                microphoneAdmissionCleanupID = cleanupID
                isMicrophoneAdmissionCleanupInProgress = true
                authorization.revoke()
                let nativeTeardownSucceeded =
                    await self.performIPhoneMicrophoneDisable(
                    on: expectedPeer,
                    authorization: authorization,
                    outputOnlyToken: outputOnlyToken
                )
                let ownsCleanup =
                    microphoneAdmissionCleanupID == cleanupID
                guard ownsCleanup,
                      microphoneOperationGeneration == operationGeneration,
                      sessionGeneration == expectedSessionGeneration,
                      peer === expectedPeer,
                      microphoneAuthorization === authorization else {
                    _ = transferTerminalIPhoneMicrophoneOutputOnlyCompletion(
                        outputOnlyToken,
                        nativeTeardownSucceeded:
                            nativeTeardownSucceeded,
                        expectedPeer: expectedPeer,
                        expectedSessionGeneration:
                            expectedSessionGeneration
                    )
                    if ownsCleanup {
                        finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    }
                    return
                }
                microphoneAuthorization = nil
                guard nativeTeardownSucceeded,
                      outputOnlyToken?.state == .succeeded else {
                    audioLifecycle.cancelPendingMicrophoneInputResume()
                    if let outputOnlyToken,
                       audioLifecycle
                        .abandonCurrentOutputOnlyTransitionRequiringReconnect(
                            outputOnlyToken
                        ),
                       microphoneOutputOnlyToken === outputOnlyToken {
                        microphoneOutputOnlyToken = nil
                    }
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone could not finish resetting. Reconnect this session to restore it."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                }
                let outputOnlyCompletion =
                    clearIPhoneMicrophoneOutputOnlyToken(
                        outputOnlyToken
                    )
                switch resolveIPhoneMicrophoneDeferredRecovery(
                    outputOnlyCompletion,
                    after: outputOnlyToken
                ) {
                case .recoveryStarted, .noDeferredRecovery:
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                case .retryableFailure:
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone audio path could not recover automatically. Tap Retry iPhone Microphone."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                case .reconnectRequired:
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone audio path could not recover automatically. Reconnect this session to restore it."
                    finishIPhoneMicrophoneAdmissionCleanup(cleanupID)
                    return
                }
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
            if !audioLifecycle.snapshot.requiresExplicitResume {
                beginIOSPlayoutProof(requestRecovery: false)
            }
        }
    }

    private func performIPhoneMicrophoneEnable(
        on peer: WebRTCPeer,
        authorization: WebRTCIOSMicrophoneAuthorization
    ) async throws {
        defer {
            recordNativeAudioTransactionTag(
                authorization.stagedTransactionTagGeneration,
                context: authorization.transaction
            )
        }
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

    private func recoverFromRetryableIPhoneMicrophoneAdmissionFailure(
        generation: UUID,
        sourcePeer: WebRTCPeer,
        transportAuthorizationGeneration expectedTransportGeneration: UUID,
        operationGeneration expectedOperationGeneration: UUID
    ) {
        guard generation == sessionGeneration,
              peer === sourcePeer,
              transportAuthorizationGeneration
                == expectedTransportGeneration,
              microphoneOperationGeneration
                == expectedOperationGeneration,
              microphoneAuthorization == nil,
              microphoneIntentEnabled,
              microphonePermissionGranted,
              applicationIsActive,
              !microphoneAwaitsPostCallRecovery,
              !microphoneIsBlockedByCall,
              audioLifecycle.microphoneActivationIsAllowed(),
              isPeerConnected,
              iceIsConnected,
              isControlChannelReady,
              !recoveryProofRequired,
              canViewScreen else {
            reconcileIPhoneMicrophone()
            return
        }

        let binding = MicrophoneAutomaticRecoveryBinding(
            sessionGeneration: generation,
            peerIdentity: ObjectIdentifier(sourcePeer),
            transportAuthorizationGeneration:
                expectedTransportGeneration
        )
        guard microphoneAutomaticRecoveryConsumedBinding
                != binding else {
            microphoneAdmissionFailedSessionGeneration = generation
            microphoneStateText = "Unavailable"
            microphoneError =
                "The iPhone microphone could not start after automatic audio recovery. Tap Retry iPhone Microphone."
            return
        }

        // Consume before the synchronous lifecycle callbacks can reenter and create the fresh
        // authorization. The recovery itself intentionally rotates audio-policy and authorization
        // generations, so only a real transport generation or advancing sender proof reopens it.
        microphoneAutomaticRecoveryConsumedBinding = binding
        microphoneAdmissionRecoveryPendingBinding = binding
        microphoneAdmissionRecoveryProofAttemptID = nil
        microphoneStateText = "Recovering audio"
        microphoneError = nil
        guard audioLifecycle
                .requestAutomaticMicrophoneAdmissionRecovery() else {
            if microphoneAdmissionRecoveryPendingBinding == binding {
                microphoneAdmissionRecoveryPendingBinding = nil
                microphoneAdmissionRecoveryProofAttemptID = nil
            }
            microphoneAdmissionFailedSessionGeneration = generation
            microphoneStateText = "Unavailable"
            microphoneError =
                "The iPhone microphone audio path could not recover automatically. Tap Retry iPhone Microphone."
            return
        }
    }

    private func currentMicrophoneAutomaticRecoveryBinding()
        -> MicrophoneAutomaticRecoveryBinding? {
        guard let peer else { return nil }
        return MicrophoneAutomaticRecoveryBinding(
            sessionGeneration: sessionGeneration,
            peerIdentity: ObjectIdentifier(peer),
            transportAuthorizationGeneration:
                transportAuthorizationGeneration
        )
    }

    @discardableResult
    private func performIPhoneMicrophoneDisable(
        on peer: WebRTCPeer,
        authorization: WebRTCIOSMicrophoneAuthorization?,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken? = nil
    ) async -> Bool {
        let result: Bool
        #if DEBUG
        if let handler = debugIPhoneMicrophoneNativeDisableHandler {
            result = await handler(
                authorization,
                outputOnlyToken
            )
        } else {
            result = await peer.disableIPhoneMicrophone(
                authorization: authorization,
                outputOnlyToken: outputOnlyToken
            )
        }
        #else
        result = await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: outputOnlyToken
        )
        #endif
        recordNativeAudioTransactionTag(
            outputOnlyToken?.stagedTransactionTagGeneration,
            context: outputOnlyToken?.transaction
        )
        return result
    }

    private func recordNativeAudioTransactionTag(
        _ tagGeneration: UInt64?,
        context: WebRTCIOSAudioTransactionContext?
    ) {
        guard let tagGeneration, let context else { return }
        audioLifecycle.recordNativeAudioTransactionTag(
            tagGeneration,
            for: context
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
        let expectedAutomaticRecoveryBinding =
            microphoneAdmissionRecoveryPendingBinding.flatMap {
                $0 == currentMicrophoneAutomaticRecoveryBinding()
                    ? $0
                    : nil
            }
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
        let nativeTeardownID = UUID()
        microphoneNativeTeardownID = nativeTeardownID
        microphoneTask = Task { @MainActor [weak self] in
            let nativeTeardownSucceeded = await self?
                .performIPhoneMicrophoneDisable(
                on: expectedPeer,
                authorization: authorization,
                outputOnlyToken: outputOnlyToken
            ) ?? false
            guard let self else { return }
            let ownsNativeTeardown =
                microphoneNativeTeardownID == nativeTeardownID
            if ownsNativeTeardown {
                microphoneNativeTeardownID = nil
            }
            guard ownsNativeTeardown,
                  sessionGeneration == expectedSessionGeneration,
                  peer === expectedPeer else {
                return
            }
            guard nativeTeardownSucceeded,
                  outputOnlyToken?.state == .succeeded else {
                audioLifecycle.cancelPendingMicrophoneInputResume()
                if let outputOnlyToken,
                   audioLifecycle
                    .abandonCurrentOutputOnlyTransitionRequiringReconnect(
                        outputOnlyToken
                    ),
                   microphoneOutputOnlyToken === outputOnlyToken {
                    microphoneOutputOnlyToken = nil
                }
                if expectedAutomaticRecoveryBinding != nil {
                    failPendingAutomaticMicrophoneRecoveryIfOwned(
                        by: expectedAutomaticRecoveryBinding,
                        message:
                            "The iPhone microphone could not finish its automatic audio reset. Reconnect this session to restore it."
                    )
                    return
                }
                guard microphoneIntentEnabled else {
                    microphoneStateText = "Off"
                    microphoneError = nil
                    return
                }
                if audioLifecycle.audioRecoveryRequiresSessionReconnect {
                    microphoneAdmissionFailedSessionGeneration =
                        expectedSessionGeneration
                    microphoneStateText = "Unavailable"
                    microphoneError =
                        "The iPhone microphone could not finish resetting. Reconnect this session to restore it."
                    return
                }
                microphoneStateText =
                    microphoneActivationBlockedStateText
                microphoneError =
                    "The iPhone microphone could not finish resetting. Tap Resume iPhone Microphone to retry."
                return
            }
            let outputOnlyCompletion =
                clearIPhoneMicrophoneOutputOnlyToken(outputOnlyToken)
            switch resolveIPhoneMicrophoneDeferredRecovery(
                outputOnlyCompletion,
                after: outputOnlyToken
            ) {
            case .noDeferredRecovery:
                guard expectedAutomaticRecoveryBinding == nil else {
                    failPendingAutomaticMicrophoneRecoveryIfOwned(
                        by: expectedAutomaticRecoveryBinding,
                        message:
                            "Automatic microphone recovery was superseded. Tap Retry iPhone Microphone."
                    )
                    return
                }
            case .retryableFailure:
                failPendingAutomaticMicrophoneRecoveryIfOwned(
                    by: expectedAutomaticRecoveryBinding,
                    message:
                        "The iPhone microphone audio path could not recover automatically. Tap Retry iPhone Microphone."
                )
                return
            case .reconnectRequired:
                failPendingAutomaticMicrophoneRecoveryIfOwned(
                    by: expectedAutomaticRecoveryBinding,
                    message:
                        "The iPhone microphone audio path could not recover automatically. Reconnect this session to restore it."
                )
                return
            case .recoveryStarted:
                return
            }
            _ = audioLifecycle.resumePendingMicrophoneInputIfPossible()
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

    private func finishIPhoneMicrophoneAdmissionCleanup(
        _ cleanupID: UUID
    ) {
        guard microphoneAdmissionCleanupID == cleanupID else {
            return
        }
        microphoneAdmissionCleanupID = nil
        isMicrophoneAdmissionCleanupInProgress = false
    }

    @discardableResult
    private func clearIPhoneMicrophoneOutputOnlyToken(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken?
    ) -> WorldwideIPhoneMicrophoneOutputOnlyCompletion {
        guard let token else { return .noDeferredRecovery }
        if microphoneOutputOnlyToken === token {
            microphoneOutputOnlyToken = nil
        }
        return audioLifecycle
            .iPhoneMicrophoneOutputOnlyTransitionDidComplete(token)
    }

    /// A peer can finish C immediately before transport uncertainty, leaving no native teardown
    /// for the peer-owned suspension handler to prepare. If the original VM continuation still
    /// owns the same peer/session/token, transfer that terminal C directly to the validated
    /// transport path instead of abandoning it behind an invalidated operation generation.
    @discardableResult
    private func transferTerminalIPhoneMicrophoneOutputOnlyCompletion(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken?,
        nativeTeardownSucceeded: Bool,
        expectedPeer: WebRTCPeer,
        expectedSessionGeneration: UUID
    ) -> Bool {
        guard let token,
              sessionGeneration == expectedSessionGeneration,
              peer === expectedPeer,
              microphoneTransportSuspensionBinding == nil,
              microphoneOutputOnlyToken === token,
              token.state != .armed,
              token.state != .executing else {
            return false
        }

        let completionWasAccepted = nativeTeardownSucceeded
            && token.state == .succeeded
            && audioLifecycle
                .completeValidatedTransportOutputOnlyTransition(token)
        if completionWasAccepted {
            microphoneOutputOnlyToken = nil
            return true
        }

        let abandoned = audioLifecycle
            .abandonCurrentOutputOnlyTransitionRequiringReconnect(token)
        if abandoned {
            microphoneOutputOnlyToken = nil
        }
        audioLifecycle.cancelPendingMicrophoneInputResume()
        microphoneAdmissionFailedSessionGeneration =
            expectedSessionGeneration
        microphoneStateText = "Unavailable"
        microphoneError =
            "The iPhone microphone could not finish its transport reset. Reconnect this session to restore it."
        return true
    }

    private func resolveIPhoneMicrophoneDeferredRecovery(
        _ completion: WorldwideIPhoneMicrophoneOutputOnlyCompletion,
        after token: WebRTCIOSOutputOnlyMicrophoneToken?
    ) -> IPhoneMicrophoneDeferredRecoveryResolution {
        switch completion {
        case .noDeferredRecovery:
            return .noDeferredRecovery
        case .recoveryFailed:
            guard let token,
                  audioLifecycle
                    .authorizeDeferredAudioRecoveryRetryAfterNativeSuccess(
                        token
                    ) else {
                if let token {
                    audioLifecycle
                        .deferredAudioRecoveryRequiresReconnect(
                            after: token
                        )
                }
                return .reconnectRequired
            }
            return .retryableFailure
        case .recoveryReady(let receipt):
            guard let token,
                  audioLifecycle.resumeDeferredAudioRecovery(
                    receipt,
                    after: token
                  ) else {
                if let token {
                    audioLifecycle
                        .deferredAudioRecoveryRequiresReconnect(
                            after: token
                        )
                }
                return .reconnectRequired
            }
            return .recoveryStarted
        }
    }

    private func requireReconnectForDroppedDeferredRecovery(
        _ completion: WorldwideIPhoneMicrophoneOutputOnlyCompletion,
        after token: WebRTCIOSOutputOnlyMicrophoneToken?
    ) {
        guard let token else { return }
        switch completion {
        case .noDeferredRecovery:
            return
        case .recoveryReady, .recoveryFailed:
            // A stale async owner must never consume the one-shot receipt. Close only the exact
            // still-tracked C chain; this is a no-op after a new session or newer recovery wins.
            audioLifecycle.deferredAudioRecoveryRequiresReconnect(
                after: token
            )
        }
    }

    private func failPendingAutomaticMicrophoneRecoveryIfOwned(
        by binding: MicrophoneAutomaticRecoveryBinding?,
        message: String
    ) {
        guard let binding,
              microphoneAdmissionRecoveryPendingBinding == binding,
              binding == currentMicrophoneAutomaticRecoveryBinding() else {
            return
        }
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
        microphoneAdmissionFailedSessionGeneration = sessionGeneration
        microphoneStateText = "Unavailable"
        microphoneError = message
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

    func screenPresentationShouldRemainMounted(
        _ lease: WorldwideScreenPresentationLease
    ) -> Bool {
        screenPresentationIsVisible(lease)
            || (screenPresentationIsCurrent(lease)
                && recoveringScreenPresentationLease == lease)
    }

    func screenVideoTrack(
        for lease: WorldwideScreenPresentationLease
    ) -> WebRTCRemoteVideoTrack? {
        screenPresentationIsVisible(lease) ? remoteVideoTrack : nil
    }

    func remoteInputIsAvailable(for lease: WorldwideScreenPresentationLease) -> Bool {
        screenPresentationIsVisible(lease) && isRemoteInputAvailable
    }

    func retireScreenPresentationLease(_ lease: WorldwideScreenPresentationLease) {
        guard currentScreenPresentationLease == lease else { return }
        if focusedWindowResizeState.interaction?.binding.lease == lease {
            cancelFocusedWindowResize()
        }
        if recoveringScreenPresentationLease == lease {
            recoveringScreenPresentationLease = nil
            screenPresentationRecoveryTask?.cancel()
            screenPresentationRecoveryTask = nil
            screenPresentationRecoveryAttemptID = nil
        }
        if screenPresentationRevealAfterRecoveryFence?.lease == lease {
            screenPresentationRevealAfterRecoveryFence = nil
        }
        if screenMediaViewerAttempt?.lease == lease {
            cancelScreenMediaViewerSuspension(
                reason: "The screen presentation lease was retired.",
                notifyPeer: true
            )
        }
        if screenMediaViewerFence?.lease == lease {
            screenMediaViewerFence = nil
        }
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
        if focusedWindowResizeState.interaction?.binding.lease == lease {
            cancelFocusedWindowResize()
        }
        return claimScreenTeardown(
            for: lease,
            allowSupersededSameSessionLease: false,
            completion: { _ in completion() }
        )
    }

    /// Immediately closes the local input gate before UI code starts an asynchronous Hide.
    func suspendRemoteInputPresentation() {
        invalidateRemoteInputState()
    }

    private func advanceScreenLivenessGeneration(
        clearRenderObservation: Bool
    ) {
        screenLivenessGeneration &+= 1
        if screenLivenessGeneration == 0 {
            screenLivenessGeneration = 1
        }
        screenLivenessClassifier.reset()
        if clearRenderObservation {
            latestScreenVideoRenderObservation = nil
            latestScreenVideoPresentationUptimeNanoseconds = nil
        }
        refreshScreenLivenessDiagnostic()
    }

    private func screenLivenessUptimeNanoseconds() -> UInt64 {
        #if DEBUG
        if let debugScreenLivenessUptimeClock {
            return debugScreenLivenessUptimeClock()
        }
        #endif
        return DispatchTime.now().uptimeNanoseconds
    }

    private var currentScreenLivenessCoverState:
        WorldwideScreenLivenessCoverState {
        if screenMediaViewerFence?.forceCover == true {
            guard let phase = screenMediaViewerAttempt?.phase else {
                return .privacy
            }
            switch phase {
            case .awaitingCoverInstallation,
                 .sendingCoveredAcknowledgementAndHide,
                 .awaitingHideAcknowledgement,
                 .awaitingMarkerReady:
                return .intentionalBandwidthPause
            case .awaitingMarkerPresentation,
                 .sendingMarkerPresentation,
                 .awaitingResumeReady,
                 .awaitingRealPresentation,
                 .sendingResumeRequest,
                 .awaitingResumedAcknowledgement:
                return .resuming
            case .resumed:
                return .none
            }
        }
        if isScreenVisible, !applicationIsActive {
            return .privacy
        }
        return isScreenVisible ? .none : .screenHidden
    }

    private func refreshScreenLivenessDiagnostic(
        at observedAtUptimeNanoseconds: UInt64? = nil
    ) {
        let observedAt = observedAtUptimeNanoseconds
            ?? screenLivenessUptimeNanoseconds()
        let renderObservation:
            WorldwideScreenLivenessRenderObservation? = if
                let latestScreenVideoRenderObservation,
                let latestScreenVideoPresentationUptimeNanoseconds {
                WorldwideScreenLivenessRenderObservation(
                    latestScreenVideoRenderObservation,
                    presentedAtUptimeNanoseconds:
                        latestScreenVideoPresentationUptimeNanoseconds
                )
            } else {
                nil
            }
        screenLivenessDiagnosticSnapshot = screenLivenessClassifier.observe(
            WorldwideScreenLivenessSample(
                generation: screenLivenessGeneration,
                observedAtUptimeNanoseconds: observedAt,
                hasRemoteVideoTrack: remoteVideoTrack != nil,
                coverState: currentScreenLivenessCoverState,
                inboundVideo: statistics?.inboundVideo,
                renderObservation: renderObservation
            )
        )
    }

    private func sendScreenClientDiagnosticsHeartbeat(
        through sourcePeer: WebRTCPeer,
        generation: UUID
    ) async {
        guard generation == sessionGeneration,
              peer === sourcePeer,
              let screenRequestID = activeScreenRequestID else {
            screenClientDiagnosticsDeliveryText = "Idle"
            return
        }
        guard nextScreenClientDiagnosticsSequence < UInt64.max else {
            screenClientDiagnosticsDeliveryText = "Local only"
            return
        }
        let isNegotiated = await sourcePeer
            .screenClientDiagnosticsIsNegotiated()
        guard generation == sessionGeneration,
              peer === sourcePeer,
              activeScreenRequestID == screenRequestID else {
            return
        }
        guard isNegotiated else {
            screenClientDiagnosticsDeliveryText = "Local only"
            return
        }

        let snapshot = screenLivenessDiagnosticSnapshot
        let heartbeat = WebRTCScreenClientDiagnosticsHeartbeat(
            sequence: nextScreenClientDiagnosticsSequence,
            screenRequestID: screenRequestID,
            liveness: Self.wireLiveness(snapshot.state),
            trackAttached: snapshot.trackAttached,
            coverVisible: snapshot.coverState != .none,
            coverReason: Self.wireCoverReason(snapshot.coverState),
            inboundBytes: snapshot.inboundBytes,
            inboundPackets: snapshot.inboundPackets,
            framesDecoded: snapshot.decodedFrames,
            framesPresented: snapshot.presentedFrames,
            contentSamples: snapshot.contentSamples,
            contentChanges: snapshot.contentChanges,
            presentationAgeMilliseconds:
                snapshot.lastPresentationAgeMilliseconds,
            frameWidth: snapshot.frameWidth,
            frameHeight: snapshot.frameHeight,
            framesPerSecond: snapshot.framesPerSecond
        )
        guard heartbeat.isValid else {
            screenClientDiagnosticsDeliveryText = "Local evidence unavailable"
            return
        }
        do {
            try await sourcePeer.sendScreenClientDiagnosticsHeartbeat(
                heartbeat
            )
            nextScreenClientDiagnosticsSequence += 1
            guard generation == sessionGeneration,
                  peer === sourcePeer else { return }
            screenClientDiagnosticsDeliveryText = "Reporting to Mac"
        } catch {
            guard generation == sessionGeneration,
                  peer === sourcePeer else { return }
            // This best-effort lane never changes the user-visible media or control state.
            screenClientDiagnosticsDeliveryText = "Heartbeat unavailable"
        }
    }

    private static func wireLiveness(
        _ state: WorldwideScreenLivenessState
    ) -> WebRTCScreenClientLiveness {
        switch state {
        case .intentionallyCovered: .intentionallyCovered
        case .covered: .covered
        case .trackMissing: .trackMissing
        case .awaitingEvidence: .awaitingEvidence
        case .inboundRTPStalled: .inboundRTPStalled
        case .decodeStalled: .decodeStalled
        case .presentationStalled: .presentationStalled
        case .presentingUnchanged: .presentingUnchanged
        case .presentingLive: .presentingLive
        }
    }

    private static func wireCoverReason(
        _ state: WorldwideScreenLivenessCoverState
    ) -> WebRTCScreenClientCoverReason {
        switch state {
        case .none: .none
        case .intentionalBandwidthPause: .bandwidthPause
        case .privacy: .privacy
        case .resuming: .resuming
        case .screenHidden: .screenHidden
        }
    }

    private func recordScreenVideoRenderObservation(
        _ observation: WebRTCVideoRenderObservation,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard screenPresentationIsCurrent(lease),
              remoteVideoTrack != nil else { return }
        let observedAt = screenLivenessUptimeNanoseconds()
        latestScreenVideoRenderObservation = observation
        latestScreenVideoPresentationUptimeNanoseconds = observedAt
        refreshScreenLivenessDiagnostic(at: observedAt)
    }

    func screenMediaViewerFence(
        for lease: WorldwideScreenPresentationLease
    ) -> WorldwideScreenMediaViewerFence? {
        guard screenPresentationIsCurrent(lease),
              screenMediaViewerFence?.lease == lease else {
            return nil
        }
        return screenMediaViewerFence
    }

    /// Called only after `WebRTCRemoteVideoView.updatePresentationFence` has synchronously placed
    /// its opaque UIKit cover above the Metal renderer. Protocol acknowledgement starts afterward.
    func screenMediaPresentationCoverDidInstall(
        coverID: UUID,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(attempt),
              attempt.lease == lease,
              attempt.id == coverID,
              attempt.phase == .awaitingCoverInstallation else {
            return
        }
        attempt.phase = .sendingCoveredAcknowledgementAndHide
        startScreenMediaCoveredAcknowledgementAndHide(for: attempt)
    }

    /// Ordinary Metal presentation nominates only the post-marker real RTP key. Marker authority
    /// comes from the separate decoded-nonce callback and can never be inferred from freshness.
    func screenVideoFrameDidRender(
        _ observation: WebRTCVideoRenderObservation,
        for lease: WorldwideScreenPresentationLease
    ) {
        recordScreenVideoRenderObservation(observation, for: lease)
        revealRecoveredScreenPresentationIfReady(for: lease)
        considerScreenMediaProofCandidate(observation, for: lease)
        validateScreenMediaSourceContinuity(for: lease)
    }

    /// A transport interruption may arrive while the negotiated bandwidth-suspension protocol has
    /// an opaque privacy cover installed. Keep that cover through the fresh Show acknowledgement,
    /// then remove it only when the replacement renderer binding presents its first current frame.
    private func revealRecoveredScreenPresentationIfReady(
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let recoveryRevealFence = screenPresentationRevealAfterRecoveryFence,
              recoveryRevealFence.lease == lease else { return }
        // `WebRTCRemoteVideoView` publishes this callback only from its current, attached binding
        // generation. Visibility therefore makes this the first admissible post-recovery frame;
        // stale detached-renderer callbacks are rejected before they reach this boundary.
        guard screenPresentationIsVisible(lease) else { return }
        guard let currentFence = screenMediaViewerFence,
              recoveryRevealFence.matches(currentFence),
              currentFence.forceCover else {
            screenPresentationRevealAfterRecoveryFence = nil
            return
        }
        screenMediaViewerFence = WorldwideScreenMediaViewerFence(
            lease: currentFence.lease,
            coverID: currentFence.coverID,
            forceCover: false,
            minimumAcceptedRTPTimestamp:
                currentFence.minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: [],
            markerProof: nil,
            proofRequestRevision: currentFence.proofRequestRevision,
            statusText: nil
        )
        screenPresentationRevealAfterRecoveryFence = nil
    }

    func screenVideoMarkerFrameDidPresentForProof(
        _ observation: WebRTCVideoMarkerPresentationProofObservation,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(attempt),
              attempt.lease == lease,
              attempt.phase == .awaitingMarkerPresentation,
              let markerReady = attempt.markerReady else {
            return
        }
        let expectedMarker = ScreenVideoInBandMarkerNonce(
            attemptID: markerReady.attemptID
        )
        // A queued callback from a replaced attempt is not evidence against the retry. Only the
        // nonce currently armed by MarkerReady can mutate this covered transaction.
        guard observation.marker == expectedMarker else { return }
        guard let primary = screenMediaPrimarySource(for: attempt),
              WorldwideScreenMediaViewerProofPolicy.acceptsMarkerProof(
                observation,
                expectedMarker: expectedMarker,
                geometry: markerReady.geometry,
                baseline: exactPrimarySource(
                    in: attempt.baselineSourceSnapshot
                ),
                current: primary
              ) else {
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The decoded marker did not match its receiver, source, or geometry."
            )
            return
        }

        // Freeze the actual decoded dimensions (for example 40x80 at 12x downscale) only after
        // the exact marker drawable presents. The real proof must use this exact same shape.
        attempt.receiverID = primary.receiverID
        attempt.sourceID = primary.sourceID
        attempt.presentedWidth = observation.width
        attempt.presentedHeight = observation.height
        let presentation = WebRTCScreenMediaMarkerPresentation(
            markerReady: markerReady,
            receiverMarkerRTPTimestamp: observation.rtpTimestamp,
            receiverID: primary.receiverID,
            sourceID: primary.sourceID,
            presentedWidth: observation.width,
            presentedHeight: observation.height
        )
        guard presentation.isValid else {
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The marker presentation did not match the negotiated geometry."
            )
            return
        }
        attempt.markerPresentation = presentation
        attempt.phase = .awaitingResumeReady
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: "Resuming screen…"
        )
        startScreenMediaMarkerPresentationSend(presentation, for: attempt)
    }

    func screenVideoFrameDidPresentForProof(
        _ observation: WebRTCVideoPresentationProofObservation,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(attempt),
              attempt.lease == lease,
              attempt.phase == .awaitingRealPresentation else {
            return
        }
        guard attempt.armedProofRTPTimestamp == observation.rtpTimestamp,
              attempt.presentedWidth == observation.width,
              attempt.presentedHeight == observation.height,
              screenMediaSourceIsStable(for: attempt) else {
            cancelScreenMediaViewerSuspension(
                reason: "The rendered screen proof changed receiver, source, or geometry.",
                notifyPeer: true
            )
            return
        }

        guard let ready = attempt.resumeReady,
              let receiverID = attempt.receiverID,
              let sourceID = attempt.sourceID else {
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The real-frame presentation was incomplete."
            )
            return
        }
        let presentation = WebRTCScreenMediaPresentation(
            resumeReady: ready,
            presentedRTPTimestamp: observation.rtpTimestamp,
            receiverID: receiverID,
            sourceID: sourceID,
            presentedWidth: observation.width,
            presentedHeight: observation.height
        )
        guard presentation.isValid else {
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The real-frame presentation was older than the resume floor."
            )
            return
        }
        attempt.resumePresentation = presentation
        attempt.armedProofRTPTimestamp = nil
        attempt.phase = .sendingResumeRequest
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: "Resuming screen…"
        )
        startScreenMediaResumeRequest(presentation, for: attempt)
    }

    func screenVideoPresentationGeometryDidChange(
        to size: CGSize,
        for lease: WorldwideScreenPresentationLease
    ) {
        if focusedWindowResizeState.interaction?.binding.lease == lease {
            cancelFocusedWindowResize()
        }
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(attempt),
              attempt.lease == lease else {
            return
        }
        if size == .zero { return }
        guard let expectedWidth = attempt.presentedWidth,
              let expectedHeight = attempt.presentedHeight else {
            guard let geometry = attempt.markerReady?.geometry else { return }
            guard size.width.isFinite,
                  size.height.isFinite else {
                cancelScreenMediaViewerSuspension(
                    reason: "The marker screen geometry became invalid during resume.",
                    notifyPeer: true
                )
                return
            }
            if !geometry.isCompatiblePresentation(
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded())
            ) {
                cancelScreenMediaViewerSuspension(
                    reason: "The marker screen geometry changed during resume.",
                    notifyPeer: true
                )
            }
            return
        }
        switch WorldwideScreenMediaViewerProofPolicy.geometryChangeDisposition(
            size,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        ) {
        case .localFloorInvalidation, .unchanged:
            return
        case .mutation:
            cancelScreenMediaViewerSuspension(
                reason: "The presented screen geometry changed during resume.",
                notifyPeer: true
            )
        }
    }

    func focusedWindowResizeContainerGeometryDidChange(
        to containerSize: CGSize,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let binding = focusedWindowResizeState.interaction?.binding,
              binding.lease == lease,
              binding.containerSize != containerSize else {
            return
        }
        cancelFocusedWindowResize()
    }

    private func receiveScreenMediaSuspension(
        _ notice: WebRTCScreenMediaSuspensionNotice,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID
    ) {
        if let existing = screenMediaViewerAttempt {
            if existing.notice == notice,
               screenMediaViewerAttemptIsCurrent(existing) {
                return
            }
            guard existing.phase == .resumed else {
                failScreenMediaViewerAttempt(
                    existing,
                    reason: "A conflicting screen suspension replaced the active proof."
                )
                return
            }
            retireScreenMediaViewerAttempt(preservingFence: true)
        }

        guard notice.isValid,
              sourceGeneration == sessionGeneration,
              peer === sourcePeer,
              let lease = currentScreenPresentationLease,
              activeScreenPresentationLease == lease,
              remoteScreenOwnerLease == lease,
              isScreenVisible,
              activeScreenRequestID == notice.screenRequestID,
              let track = remoteVideoTrack else {
            failUnmatchedScreenMediaSuspension(
                notice: notice,
                sourcePeer: sourcePeer,
                reason: "A screen suspension did not match the visible presentation.",
                sourceGeneration: sourceGeneration
            )
            return
        }

        let attempt = WorldwideScreenMediaViewerAttempt(
            notice: notice,
            lease: lease,
            sessionGeneration: sourceGeneration,
            expectedPeer: sourcePeer,
            expectedTrack: track
        )
        screenMediaViewerAttempt = attempt
        // Input revocation and cover publication are MainActor-synchronous with receipt. No actor
        // send begins until the mounted UIKit renderer reports that this exact cover ID is installed.
        invalidateRemoteInputState()
        stateText = "Screen paused"
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: WorldwideScreenLivenessCoverState
                .intentionalBandwidthPause.statusText
        )
    }

    private func receiveScreenMediaMarkerReady(
        _ ready: WebRTCScreenMediaMarkerReady,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(
                attempt,
                sourcePeer: sourcePeer,
                sourceGeneration: sourceGeneration
              ),
              ready.belongs(to: attempt.notice),
              ready.isValid else {
            cancelScreenMediaViewerSuspension(
                reason: "The marker boundary was stale or out of order.",
                notifyPeer: true
            )
            return
        }
        if attempt.phase != .awaitingMarkerReady {
            if attempt.phase != .resumed,
               WorldwideScreenMediaViewerProofPolicy.isSameSuspensionRetry(
                ready,
                replacing: attempt.markerReady?.attemptID,
                notice: attempt.notice
            ) {
                resetScreenMediaViewerProbeForRetry(attempt)
            } else if attempt.markerReady == ready {
                return
            } else {
                cancelScreenMediaViewerSuspension(
                    reason: "The marker boundary was stale or out of order.",
                    notifyPeer: true
                )
                return
            }
        }
        guard attempt.phase == .awaitingMarkerReady else { return }
        attempt.markerReady = ready
        attempt.phase = .awaitingMarkerPresentation
        attempt.proofRequestRevision &+= 1
        if attempt.proofRequestRevision == 0 {
            attempt.proofRequestRevision = 1
        }
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: "Resuming screen…"
        )
    }

    private func resetScreenMediaViewerProbeForRetry(
        _ attempt: WorldwideScreenMediaViewerAttempt
    ) {
        guard screenMediaViewerAttempt === attempt else { return }
        screenMediaMarkerPresentationTask?.cancel()
        screenMediaMarkerPresentationTask = nil
        screenMediaMarkerPresentationTaskID = nil
        screenMediaResumeRequestTask?.cancel()
        screenMediaResumeRequestTask = nil
        screenMediaResumeRequestTaskID = nil
        attempt.earlyResumedAcknowledgement?.authorization?.revoke()
        attempt.earlyResumedAcknowledgement = nil
        attempt.markerReady = nil
        attempt.markerPresentation = nil
        attempt.resumeReady = nil
        attempt.resumePresentation = nil
        attempt.resumeRequestID = nil
        attempt.receiverID = nil
        attempt.sourceID = nil
        attempt.presentedWidth = nil
        attempt.presentedHeight = nil
        attempt.armedProofRTPTimestamp = nil
        attempt.minimumAcceptedRTPTimestamp = nil
        attempt.phase = .awaitingMarkerReady
        attempt.proofRequestRevision &+= 1
        if attempt.proofRequestRevision == 0 {
            attempt.proofRequestRevision = 1
        }
        // The original cover/Hide transaction and lease binding stay intact. Only evidence owned
        // by the failed encoder attempt is retired, so no retry can flash old media or regain input.
        if let currentFence = screenMediaViewerFence,
           currentFence.lease == attempt.lease,
           currentFence.coverID == attempt.id {
            screenMediaViewerFence = WorldwideScreenMediaViewerProofPolicy
                .coveredRetryFence(
                    from: currentFence,
                    proofRequestRevision: attempt.proofRequestRevision
                )
        } else {
            publishScreenMediaViewerFence(
                for: attempt,
                forceCover: true,
                statusText: "Resuming screen…"
            )
        }
    }

    private func receiveScreenMediaResumeReady(
        _ ready: WebRTCScreenMediaResumeReady,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(
                attempt,
                sourcePeer: sourcePeer,
                sourceGeneration: sourceGeneration
              ),
              attempt.phase == .awaitingResumeReady,
              let markerPresentation = attempt.markerPresentation,
              ready.markerPresentation == markerPresentation,
              ready.isValid,
              ready.geometry == markerPresentation.markerReady.geometry,
              screenMediaSourceIsStable(for: attempt) else {
            cancelScreenMediaViewerSuspension(
                reason: "The translated receiver resume floor was stale or mismatched.",
                notifyPeer: true
            )
            return
        }
        attempt.resumeReady = ready
        attempt.minimumAcceptedRTPTimestamp =
            ready.receiverRealFrameFloorRTPTimestamp
        attempt.phase = .awaitingRealPresentation
        attempt.proofRequestRevision &+= 1
        if attempt.proofRequestRevision == 0 {
            attempt.proofRequestRevision = 1
        }
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: "Resuming screen…"
        )
    }

    private func receiveScreenMediaResumedAcknowledgement(
        _ acknowledgement: WebRTCScreenMediaResumedAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID
    ) {
        guard let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(
                attempt,
                sourcePeer: sourcePeer,
                sourceGeneration: sourceGeneration
              ),
              attempt.phase == .sendingResumeRequest
                || attempt.phase == .awaitingResumedAcknowledgement else {
            inputAuthorization?.revoke()
            cancelScreenMediaViewerSuspension(
                reason: "The resumed acknowledgement arrived outside its presentation lease.",
                notifyPeer: true
            )
            return
        }

        guard let requestID = attempt.resumeRequestID else {
            attempt.earlyResumedAcknowledgement?.authorization?.revoke()
            attempt.earlyResumedAcknowledgement = (
                acknowledgement,
                inputAuthorization
            )
            return
        }
        commitScreenMediaResumedAcknowledgement(
            acknowledgement,
            inputAuthorization: inputAuthorization,
            requestID: requestID,
            for: attempt
        )
    }

    private func startScreenMediaCoveredAcknowledgementAndHide(
        for attempt: WorldwideScreenMediaViewerAttempt
    ) {
        screenMediaCoveredHideTask?.cancel()
        let acknowledgement = WebRTCScreenMediaCoveredAcknowledgement(
            suspension: attempt.notice
        )
        let attemptID = attempt.id
        let sourcePeer = attempt.expectedPeer
        screenMediaCoveredHideTask = Task { @MainActor [weak self] in
            do {
                try await sourcePeer.sendScreenMediaCoveredAcknowledgement(
                    acknowledgement
                )
                guard let self,
                      let current = self.screenMediaViewerAttempt,
                      current.id == attemptID,
                      self.screenMediaViewerAttemptIsCurrent(current),
                      current.phase == .sendingCoveredAcknowledgementAndHide else {
                    return
                }
                let requestID = try await sourcePeer.setScreenVisible(false)
                self.recordScreenMediaHideRequest(
                    requestID,
                    sourcePeer: sourcePeer,
                    for: current
                )
            } catch {
                self?.failScreenMediaViewerAttempt(
                    attempt,
                    reason: "The covered screen could not enter its hidden transport state."
                )
            }
        }
    }

    private func recordScreenMediaHideRequest(
        _ requestID: UInt64,
        sourcePeer: WebRTCPeer,
        for attempt: WorldwideScreenMediaViewerAttempt
    ) {
        guard screenMediaViewerAttemptIsCurrent(attempt),
              attempt.phase == .sendingCoveredAcknowledgementAndHide,
              requestID > 0 else {
            return
        }
        let key = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: attempt.sessionGeneration,
            requestID: requestID
        )
        attempt.hideRequestKey = key
        attempt.phase = .awaitingHideAcknowledgement
        if let early = earlyControlAcknowledgements.removeValue(forKey: key) {
            guard screenAcknowledgementPeer(
                early.sourcePeer,
                matches: sourcePeer
            ) else {
                early.inputAuthorization?.revoke()
                failScreenMediaViewerAttempt(
                    attempt,
                    reason: "The suspension Hide acknowledgement came from another peer."
                )
                return
            }
            handleScreenMediaHideAcknowledgement(
                early.acknowledgement,
                inputAuthorization: early.inputAuthorization,
                sourcePeer: sourcePeer,
                sourceGeneration: attempt.sessionGeneration,
                attempt: attempt
            )
        }
    }

    private func handleScreenMediaHideAcknowledgement(
        _ acknowledgement: WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        sourcePeer: WebRTCPeer,
        sourceGeneration: UUID,
        attempt: WorldwideScreenMediaViewerAttempt
    ) {
        inputAuthorization?.revoke()
        guard screenMediaViewerAttemptIsCurrent(
                attempt,
                sourcePeer: sourcePeer,
                sourceGeneration: sourceGeneration
              ),
              attempt.phase == .awaitingHideAcknowledgement,
              attempt.hideRequestKey?.requestID == acknowledgement.id,
              acknowledgement.state == .inactive else {
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The suspension Hide did not reach the inactive state."
            )
            return
        }
        if let key = attempt.hideRequestKey {
            retireScreenVisibilityRequestKey(key)
        }
        screenAcknowledgementOracle = WorldwideScreenAcknowledgementOracleSnapshot(
            sessionGeneration: sourceGeneration,
            requestID: acknowledgement.id,
            command: .hide,
            state: .inactive
        )
        // This Hide is transport-only. The exact lease remains logically visible and owns the
        // mounted, covered renderer until the typed resumed acknowledgement commits.
        attempt.phase = .awaitingMarkerReady
        refreshScreenLivenessDiagnostic()
        stateText = "Screen paused"
    }

    private func considerScreenMediaProofCandidate(
        _ observation: WebRTCVideoRenderObservation?,
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let observation,
              let attempt = screenMediaViewerAttempt,
              screenMediaViewerAttemptIsCurrent(attempt),
              attempt.lease == lease,
              attempt.phase == .awaitingRealPresentation,
              attempt.armedProofRTPTimestamp == nil,
              let primary = screenMediaPrimarySource(for: attempt),
              let expectedWidth = attempt.presentedWidth,
              let expectedHeight = attempt.presentedHeight else {
            return
        }

        guard let receiverID = attempt.receiverID,
              let sourceID = attempt.sourceID,
              let floor = attempt.minimumAcceptedRTPTimestamp,
              WorldwideScreenMediaViewerProofPolicy
                .acceptsRealCandidate(
                    rtpTimestamp: observation.rtpTimestamp,
                    width: observation.width,
                    height: observation.height,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    minimumRTPTimestamp: floor,
                    receiverID: receiverID,
                    sourceID: sourceID,
                    current: primary
                ) else { return }

        attempt.armedProofRTPTimestamp = observation.rtpTimestamp
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: true,
            statusText: "Resuming screen…"
        )
    }

    private func startScreenMediaMarkerPresentationSend(
        _ presentation: WebRTCScreenMediaMarkerPresentation,
        for attempt: WorldwideScreenMediaViewerAttempt
    ) {
        screenMediaMarkerPresentationTask?.cancel()
        let attemptID = attempt.id
        let taskID = UUID()
        screenMediaMarkerPresentationTaskID = taskID
        let sourcePeer = attempt.expectedPeer
        screenMediaMarkerPresentationTask = Task { @MainActor [weak self] in
            do {
                try await sourcePeer.sendScreenMediaMarkerPresentation(
                    presentation
                )
                guard let self,
                      self.screenMediaMarkerPresentationTaskID == taskID,
                      let current = self.screenMediaViewerAttempt,
                      current.id == attemptID,
                      self.screenMediaViewerAttemptIsCurrent(current),
                      current.phase == .awaitingResumeReady,
                      current.markerReady?.attemptID
                        == presentation.markerReady.attemptID,
                      current.markerPresentation == presentation else {
                    return
                }
            } catch {
                guard let self,
                      self.screenMediaMarkerPresentationTaskID == taskID,
                      let current = self.screenMediaViewerAttempt,
                      current === attempt,
                      current.id == attemptID,
                      self.screenMediaViewerAttemptIsCurrent(current),
                      current.phase == .awaitingResumeReady,
                      current.markerReady?.attemptID
                        == presentation.markerReady.attemptID,
                      current.markerPresentation == presentation else {
                    return
                }
                self.failScreenMediaViewerAttempt(
                    current,
                    reason: "The marker presentation could not be sent."
                )
            }
        }
    }

    private func startScreenMediaResumeRequest(
        _ presentation: WebRTCScreenMediaPresentation,
        for attempt: WorldwideScreenMediaViewerAttempt
    ) {
        screenMediaResumeRequestTask?.cancel()
        let attemptID = attempt.id
        let taskID = UUID()
        screenMediaResumeRequestTaskID = taskID
        let sourcePeer = attempt.expectedPeer
        screenMediaResumeRequestTask = Task { @MainActor [weak self] in
            do {
                let requestID = try await sourcePeer.requestScreenMediaResume(
                    presentation: presentation
                )
                guard let self,
                      self.screenMediaResumeRequestTaskID == taskID,
                      let current = self.screenMediaViewerAttempt,
                      current.id == attemptID,
                      self.screenMediaViewerAttemptIsCurrent(current),
                      current.phase == .sendingResumeRequest,
                      current.resumePresentation == presentation else {
                    return
                }
                current.resumeRequestID = requestID
                current.phase = .awaitingResumedAcknowledgement
                if let early = current.earlyResumedAcknowledgement {
                    current.earlyResumedAcknowledgement = nil
                    self.commitScreenMediaResumedAcknowledgement(
                        early.acknowledgement,
                        inputAuthorization: early.authorization,
                        requestID: requestID,
                        for: current
                    )
                }
            } catch {
                guard let self,
                      self.screenMediaResumeRequestTaskID == taskID,
                      let current = self.screenMediaViewerAttempt,
                      current === attempt,
                      current.id == attemptID,
                      self.screenMediaViewerAttemptIsCurrent(current),
                      current.phase == .sendingResumeRequest,
                      current.resumePresentation == presentation,
                      current.resumeRequestID == nil else {
                    return
                }
                self.failScreenMediaViewerAttempt(
                    current,
                    reason: "The exact screen resume request could not be sent."
                )
            }
        }
    }

    private func commitScreenMediaResumedAcknowledgement(
        _ acknowledgement: WebRTCScreenMediaResumedAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?,
        requestID: UInt64,
        for attempt: WorldwideScreenMediaViewerAttempt
    ) {
        guard screenMediaViewerAttemptIsCurrent(attempt),
              attempt.phase == .awaitingResumedAcknowledgement,
              let presentation = attempt.resumePresentation,
              WorldwideScreenMediaViewerProofPolicy
                .resumedAcknowledgementMatches(
                    acknowledgement,
                    requestID: requestID,
                    presentation: presentation,
                    screenRequestID: attempt.notice.screenRequestID,
                    inputAuthorizationIsValid:
                        inputAuthorization?.isValid == true
                ),
              screenMediaSourceIsStable(for: attempt) else {
            inputAuthorization?.revoke()
            failScreenMediaViewerAttempt(
                attempt,
                reason: "The resumed acknowledgement did not match the exact presentation."
            )
            return
        }

        let capability = acknowledgement.inputCapability
        if capability == nil {
            inputAuthorization?.revoke()
        }
        installRemoteInputCapability(
            capability,
            authorization: capability == nil ? nil : inputAuthorization
        )
        attempt.phase = .resumed
        stateText = "Screen live"
        publishScreenMediaViewerFence(
            for: attempt,
            forceCover: false,
            statusText: nil
        )
    }

    private func screenMediaViewerAttemptIsCurrent(
        _ attempt: WorldwideScreenMediaViewerAttempt,
        sourcePeer: WebRTCPeer? = nil,
        sourceGeneration: UUID? = nil
    ) -> Bool {
        guard screenMediaViewerAttempt === attempt,
              attempt.sessionGeneration == sessionGeneration,
              sourceGeneration == nil || sourceGeneration == sessionGeneration,
              peer === attempt.expectedPeer,
              sourcePeer == nil || sourcePeer === attempt.expectedPeer,
              currentScreenPresentationLease == attempt.lease,
              activeScreenPresentationLease == attempt.lease,
              remoteScreenOwnerLease == attempt.lease,
              activeScreenRequestID == attempt.notice.screenRequestID,
              isScreenVisible,
              remoteVideoTrack.map({ ObjectIdentifier($0) })
                == attempt.expectedTrackIdentity else {
            return false
        }
        return true
    }

    private func exactPrimarySource(
        in snapshot: WebRTCRemoteVideoSourceSnapshot
    ) -> WorldwideScreenMediaPrimarySource? {
        WorldwideScreenMediaViewerProofPolicy.exactPrimarySource(in: snapshot)
    }

    private func screenMediaPrimarySource(
        for attempt: WorldwideScreenMediaViewerAttempt
    ) -> WorldwideScreenMediaPrimarySource? {
        guard screenMediaViewerAttemptIsCurrent(attempt),
              let source = exactPrimarySource(
                in: attempt.expectedTrack.sourceSnapshot()
              ),
              source.receiverID == attempt.expectedTrack.receiverID else {
            return nil
        }
        if let receiverID = attempt.receiverID,
           receiverID != source.receiverID {
            return nil
        }
        if let sourceID = attempt.sourceID,
           sourceID != source.sourceID {
            return nil
        }
        return source
    }

    private func screenMediaSourceIsStable(
        for attempt: WorldwideScreenMediaViewerAttempt
    ) -> Bool {
        guard let source = screenMediaPrimarySource(for: attempt),
              let receiverID = attempt.receiverID,
              let sourceID = attempt.sourceID else {
            return false
        }
        return source.receiverID == receiverID && source.sourceID == sourceID
    }

    private func validateScreenMediaSourceContinuity(
        for lease: WorldwideScreenPresentationLease
    ) {
        guard let attempt = screenMediaViewerAttempt,
              attempt.lease == lease,
              attempt.receiverID != nil,
              attempt.sourceID != nil,
              !screenMediaSourceIsStable(for: attempt) else {
            return
        }
        cancelScreenMediaViewerSuspension(
            reason: "The primary screen source changed during resume.",
            notifyPeer: true
        )
    }

    private func publishScreenMediaViewerFence(
        for attempt: WorldwideScreenMediaViewerAttempt,
        forceCover: Bool,
        statusText: String?
    ) {
        guard screenMediaViewerAttempt === attempt else { return }
        let markerProof = attempt.phase == .awaitingMarkerPresentation
            ? attempt.markerReady.map {
                ScreenVideoInBandMarkerNonce(attemptID: $0.attemptID)
            }
            : nil
        screenMediaViewerFence = WorldwideScreenMediaViewerFence(
            lease: attempt.lease,
            coverID: attempt.id,
            forceCover: forceCover,
            minimumAcceptedRTPTimestamp:
                attempt.minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: attempt.armedProofRTPTimestamp.map { [$0] } ?? [],
            markerProof: markerProof,
            proofRequestRevision: attempt.proofRequestRevision,
            statusText: statusText
        )
    }

    private func failScreenMediaViewerAttempt(
        _ attempt: WorldwideScreenMediaViewerAttempt,
        reason: String
    ) {
        guard screenMediaViewerAttempt === attempt else { return }
        cancelScreenMediaViewerSuspension(reason: reason, notifyPeer: true)
    }

    private func retireScreenMediaViewerAttempt(preservingFence: Bool) {
        screenMediaCoveredHideTask?.cancel()
        screenMediaCoveredHideTask = nil
        screenMediaMarkerPresentationTask?.cancel()
        screenMediaMarkerPresentationTask = nil
        screenMediaMarkerPresentationTaskID = nil
        screenMediaResumeRequestTask?.cancel()
        screenMediaResumeRequestTask = nil
        screenMediaResumeRequestTaskID = nil
        screenMediaViewerAttempt?.earlyResumedAcknowledgement?
            .authorization?.revoke()
        screenMediaViewerAttempt = nil
        if !preservingFence {
            screenMediaViewerFence = nil
        }
    }

    private func cancelScreenMediaViewerSuspension(
        reason: String,
        notifyPeer: Bool
    ) {
        guard let attempt = screenMediaViewerAttempt else {
            return
        }
        let expectedPeer = attempt.expectedPeer
        let expectedNotice = attempt.notice
        let retainedFence = screenMediaViewerFence
        retireScreenMediaViewerAttempt(preservingFence: true)
        invalidateRemoteInputState()
        if let retainedFence {
            screenMediaViewerFence = WorldwideScreenMediaViewerFence(
                lease: retainedFence.lease,
                coverID: retainedFence.coverID,
                forceCover: true,
                minimumAcceptedRTPTimestamp:
                    retainedFence.minimumAcceptedRTPTimestamp,
                proofRTPTimestamps: [],
                markerProof: nil,
                proofRequestRevision: retainedFence.proofRequestRevision,
                statusText: "Screen paused for privacy"
            )
        }
        stateText = "Screen paused"
        lastDiagnostic = reason
        guard notifyPeer else { return }
        cancelScreenMediaSuspension(
            on: expectedPeer,
            matching: expectedNotice,
            reason: reason
        )
    }

    private func failUnmatchedScreenMediaSuspension(
        notice: WebRTCScreenMediaSuspensionNotice,
        sourcePeer: WebRTCPeer,
        reason: String,
        sourceGeneration: UUID
    ) {
        guard sourceGeneration == sessionGeneration,
              peer === sourcePeer else {
            return
        }
        invalidateRemoteInputState()
        if let lease = currentScreenPresentationLease,
           lease.sessionGeneration == sourceGeneration {
            screenMediaViewerFence = WorldwideScreenMediaViewerFence(
                lease: lease,
                coverID: UUID(),
                forceCover: true,
                minimumAcceptedRTPTimestamp: nil,
                proofRTPTimestamps: [],
                markerProof: nil,
                proofRequestRevision: 0,
                statusText: "Screen paused for privacy"
            )
        }
        stateText = "Screen paused"
        lastDiagnostic = reason
        cancelScreenMediaSuspension(
            on: sourcePeer,
            matching: notice,
            reason: reason
        )
    }

    private func cancelScreenMediaSuspension(
        on sourcePeer: WebRTCPeer,
        matching notice: WebRTCScreenMediaSuspensionNotice,
        reason: String
    ) {
        #if DEBUG
        if let debugScreenMediaCancellationObserver {
            debugScreenMediaCancellationObserver(sourcePeer, reason)
            return
        }
        #endif
        Task {
            await sourcePeer.cancelScreenMediaSuspension(
                matching: notice,
                reason: reason
            )
        }
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

        if screenMediaViewerAttempt?.lease == lease {
            cancelScreenMediaViewerSuspension(
                reason: "The viewer closed during screen resume.",
                notifyPeer: true
            )
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
        // A locally dismissed viewer must not leave an in-flight Show owning the serial drain.
        // Queue Hide first, then retire/resume the same-lease Show so the drain advances directly
        // into the fail-closed teardown even after the presentation lease itself is retired.
        supersedeScreenShow(for: lease)
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

    @discardableResult
    func beginFocusedWindowResize(
        for lease: WorldwideScreenPresentationLease,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) -> Bool {
        guard let binding = focusedWindowResizeBinding(
            for: lease,
            containerSize: containerSize,
            viewerVideoSize: viewerVideoSize
        ) else {
            cancelFocusedWindowResize()
            return false
        }

        cancelFocusedWindowResize()
        discardPendingRemoteScrolls()
        retireRemotePointerIntentPreservingKeyboardFocus()
        let interactionID = UUID()
        let operation = FocusedWindowResizePendingOperation.targetRequest(
            operationID: UUID(),
            focusGeneration: focusedInputGeneration
        )
        focusedWindowResizeState = .active(
            FocusedWindowResizeInteraction(
                id: interactionID,
                binding: binding,
                target: nil,
                pending: operation
            )
        )
        let sendAuthorization = currentFocusedWindowResizeSendAuthorization()
        enqueueRemoteInput(
            .requestFocusedWindowResizeTarget,
            viewerVideoSize: Self.remoteInputVideoSize(from: viewerVideoSize),
            sendAuthorization: sendAuthorization,
            focusedWindowResizeInteractionID: interactionID,
            focusedWindowResizeOperation: operation
        )
        return focusedWindowResizeState.interaction?.id == interactionID
            && sendAuthorization.isValid
    }

    func selectWindowForFocusedResize(
        at normalizedPoint: CGPoint,
        for lease: WorldwideScreenPresentationLease,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) {
        guard Self.isValidNormalizedRemoteInputPoint(normalizedPoint),
              var interaction = currentFocusedWindowResizeInteraction(
                  for: lease,
                  containerSize: containerSize,
                  viewerVideoSize: viewerVideoSize
              ),
              interaction.pending == nil,
              let sendAuthorization = focusedWindowResizeSendAuthorization,
              sendAuthorization.isValid else {
            return
        }

        let operation = FocusedWindowResizePendingOperation.selection(
            operationID: UUID(),
            focusGeneration: focusedInputGeneration
        )
        interaction.target = nil
        interaction.pending = operation
        focusedWindowResizeState = .active(interaction)
        enqueueRemoteInput(
            .selectWindowForResize(
                at: WebRTCNormalizedPoint(
                    x: Double(normalizedPoint.x),
                    y: Double(normalizedPoint.y)
                )
            ),
            viewerVideoSize: Self.remoteInputVideoSize(from: viewerVideoSize),
            sendAuthorization: sendAuthorization,
            focusedWindowResizeInteractionID: interaction.id,
            focusedWindowResizeOperation: operation
        )
    }

    func commitFocusedWindowResize(
        targetGeneration: UUID,
        startNormalizedPoint: CGPoint,
        endNormalizedPoint: CGPoint,
        for lease: WorldwideScreenPresentationLease,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) {
        guard Self.isValidNormalizedRemoteInputPoint(startNormalizedPoint),
              Self.isValidNormalizedRemoteInputPoint(endNormalizedPoint),
              var interaction = currentFocusedWindowResizeInteraction(
                  for: lease,
                  containerSize: containerSize,
                  viewerVideoSize: viewerVideoSize
              ),
              interaction.pending == nil,
              interaction.target?.generation == targetGeneration,
              let sendAuthorization = focusedWindowResizeSendAuthorization,
              sendAuthorization.isValid else {
            return
        }

        let operation = FocusedWindowResizePendingOperation.commit(
            operationID: UUID(),
            consumedTargetGeneration: targetGeneration,
            focusGeneration: focusedInputGeneration
        )
        // The consumed generation is one-shot. Feedback may install only a fresh successor.
        interaction.target = nil
        interaction.pending = operation
        focusedWindowResizeState = .active(interaction)
        enqueueRemoteInput(
            .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: WebRTCNormalizedPoint(
                    x: Double(startNormalizedPoint.x),
                    y: Double(startNormalizedPoint.y)
                ),
                end: WebRTCNormalizedPoint(
                    x: Double(endNormalizedPoint.x),
                    y: Double(endNormalizedPoint.y)
                )
            ),
            viewerVideoSize: Self.remoteInputVideoSize(from: viewerVideoSize),
            sendAuthorization: sendAuthorization,
            focusedWindowResizeInteractionID: interaction.id,
            focusedWindowResizeOperation: operation
        )
    }

    /// Revokes only focused-window resize work. Keyboard focus and ordinary text packets remain
    /// owned by their independent authenticated generations.
    func cancelFocusedWindowResize() {
        focusedWindowResizeSendAuthorization?.revoke()
        focusedWindowResizeSendAuthorization = nil
        remoteInputQueue.removeAll(where: {
            $0.focusedWindowResizeOperation != nil
        })
        let pendingRequests: [(
            requestID: UInt64,
            operation: FocusedWindowResizePendingOperation,
            requestScope: RemoteInputRequestScope
        )] = pendingRemoteInputs.compactMap { requestID, pending in
            guard case .focusedWindowResize(_, let operation) = pending.kind else {
                return nil
            }
            return (
                requestID: requestID,
                operation: operation,
                requestScope: pending.requestScope
            )
        }
        for (requestID, operation, requestScope) in pendingRequests {
            pendingRemoteInputs.removeValue(forKey: requestID)
            earlyRemoteInputFeedback.removeValue(forKey: requestID)
            retireFocusedWindowResizeRequestID(
                requestID,
                operation: operation,
                requestScope: requestScope
            )
        }
        if !pendingRequests.isEmpty {
            let retired = Set(pendingRequests.map(\.requestID))
            pendingRemoteInputOrder.removeAll(where: retired.contains)
        }
        focusedWindowResizeState = .inactive
    }

    private func remoteVideoTrackIdentityWillChange() {
        discardPendingRemoteScrolls()
        cancelFocusedWindowResize()
    }

    private func retireFocusedWindowResizeRequestID(
        _ requestID: UInt64,
        operation: FocusedWindowResizePendingOperation,
        requestScope: RemoteInputRequestScope
    ) {
        let key = RetiredFocusedWindowResizeRequestKey(
            requestID: requestID,
            requestScope: requestScope
        )
        guard retiredFocusedWindowResizeRequests[key] == nil else {
            return
        }
        retiredFocusedWindowResizeRequests[key] =
            RetiredFocusedWindowResizeRequest(operation: operation)
        retiredFocusedWindowResizeRequestKeyOrder.append(key)
        while retiredFocusedWindowResizeRequestKeyOrder.count > 256 {
            let oldest = retiredFocusedWindowResizeRequestKeyOrder.removeFirst()
            retiredFocusedWindowResizeRequests.removeValue(forKey: oldest)
        }
    }

    private func focusedWindowResizeBinding(
        for lease: WorldwideScreenPresentationLease,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) -> FocusedWindowResizeBinding? {
        guard remoteInputIsAvailable(for: lease),
              isFocusedWindowResizeAvailable,
              let capability = remoteInputCapability,
              capability.supportsFocusedWindowResize,
              let trackIdentity = focusedWindowResizeTrackIdentity(for: lease),
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              containerSize.width > 0,
              containerSize.height > 0,
              Self.remoteInputVideoSize(from: viewerVideoSize) != nil else {
            return nil
        }
        return FocusedWindowResizeBinding(
            lease: lease,
            inputSessionID: capability.inputSessionID,
            screenRequestID: capability.screenRequestID,
            trackIdentity: trackIdentity,
            containerSize: containerSize,
            viewerVideoSize: viewerVideoSize
        )
    }

    private func currentFocusedWindowResizeInteraction(
        for lease: WorldwideScreenPresentationLease,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) -> FocusedWindowResizeInteraction? {
        guard let interaction = focusedWindowResizeState.interaction,
              interaction.binding.lease == lease,
              interaction.binding.containerSize == containerSize,
              interaction.binding.viewerVideoSize == viewerVideoSize,
              focusedWindowResizeInteractionIsCurrent(interaction) else {
            cancelFocusedWindowResize()
            return nil
        }
        return interaction
    }

    private func focusedWindowResizeInteractionIsCurrent(
        _ interaction: FocusedWindowResizeInteraction
    ) -> Bool {
        let binding = interaction.binding
        return remoteInputIsAvailable(for: binding.lease)
            && isFocusedWindowResizeAvailable
            && remoteInputCapability?.inputSessionID == binding.inputSessionID
            && remoteInputCapability?.screenRequestID == binding.screenRequestID
            && focusedWindowResizeTrackIdentity(for: binding.lease)
                == binding.trackIdentity
            && focusedWindowResizeSendAuthorization?.isValid == true
    }

    private func focusedWindowResizeTrackIdentity(
        for lease: WorldwideScreenPresentationLease
    ) -> ObjectIdentifier? {
        if let track = screenVideoTrack(for: lease) {
            return ObjectIdentifier(track)
        }
        #if DEBUG
        if screenPresentationIsVisible(lease),
           let debugFocusedWindowResizeTrackOwner {
            return ObjectIdentifier(debugFocusedWindowResizeTrackOwner)
        }
        #endif
        return nil
    }

    private func currentFocusedWindowResizeSendAuthorization()
        -> WebRTCInputSendAuthorization {
        if let focusedWindowResizeSendAuthorization,
           focusedWindowResizeSendAuthorization.isValid {
            return focusedWindowResizeSendAuthorization
        }
        let authorization = WebRTCInputSendAuthorization()
        focusedWindowResizeSendAuthorization = authorization
        return authorization
    }

    private static func isValidNormalizedRemoteInputPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && (0 ... 1).contains(point.x)
            && (0 ... 1).contains(point.y)
    }

    func sendRemoteTap(
        normalizedPoint: CGPoint,
        viewerVideoSize: CGSize
    ) {
        guard isRemoteInputAvailable,
              !focusedWindowResizeState.isActive,
              normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite,
              let viewerVideoSize = Self.remoteInputVideoSize(from: viewerVideoSize) else {
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
            pointerIntentID: pointerIntentID,
            viewerVideoSize: viewerVideoSize
        )
    }

    func sendRemotePrimaryDrag(
        startNormalizedPoint: CGPoint,
        endNormalizedPoint: CGPoint,
        viewerVideoSize: CGSize
    ) {
        guard isRemotePrimaryDragAvailable,
              !focusedWindowResizeState.isActive,
              startNormalizedPoint.x.isFinite,
              startNormalizedPoint.y.isFinite,
              endNormalizedPoint.x.isFinite,
              endNormalizedPoint.y.isFinite,
              let viewerVideoSize = Self.remoteInputVideoSize(from: viewerVideoSize) else {
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
            pointerIntentID: pointerIntentID,
            viewerVideoSize: viewerVideoSize
        )
    }

    /// Begins one pointer intent for the complete swipe. Incremental updates reuse its identifier
    /// while the framebuffer-scaled accumulator coalesces movement before the existing queue.
    func beginRemoteScroll(
        normalizedAnchor: CGPoint,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) -> UUID? {
        guard isRemoteScrollAvailable,
              !focusedWindowResizeState.isActive,
              normalizedAnchor.x.isFinite,
              normalizedAnchor.y.isFinite,
              (0 ... 1).contains(normalizedAnchor.x),
              (0 ... 1).contains(normalizedAnchor.y),
              let protocolVideoSize = Self.remoteInputVideoSize(from: viewerVideoSize),
              let accumulator = RemoteScrollDeltaAccumulator(
                containerSize: containerSize,
                videoSize: viewerVideoSize
              ),
              let capability = remoteInputCapability,
              capability.supportsScroll,
              let authorization = remoteInputAuthorization,
              authorization.isValid else {
            return nil
        }

        if activeRemoteScroll != nil {
            discardPendingRemoteScrolls()
        }
        let sendAuthorization = currentRemoteScrollSendAuthorization()
        let gestureID = UUID()
        activeRemoteScroll = ActiveRemoteScroll(
            gestureID: gestureID,
            anchor: WebRTCNormalizedPoint(
                x: Double(normalizedAnchor.x),
                y: Double(normalizedAnchor.y)
            ),
            containerSize: containerSize,
            viewerVideoSize: viewerVideoSize,
            protocolVideoSize: protocolVideoSize,
            capability: capability,
            authorization: authorization,
            sessionGeneration: sessionGeneration,
            inputGeneration: remoteInputGeneration,
            pointerIntentID: beginRemotePointerIntent(),
            sendAuthorization: sendAuthorization,
            accumulator: accumulator,
            canFlushImmediately: true,
            isEnding: false
        )
        return gestureID
    }

    func appendRemoteScroll(
        gestureID: UUID,
        viewDelta: CGSize,
        containerSize: CGSize,
        viewerVideoSize: CGSize
    ) {
        guard var scroll = activeRemoteScroll,
              scroll.gestureID == gestureID else { return }
        guard remoteScrollIsCurrent(scroll),
              !scroll.isEnding,
              scroll.containerSize == containerSize,
              scroll.viewerVideoSize == viewerVideoSize,
              scroll.accumulator.append(viewDelta: viewDelta) else {
            cancelRemoteScroll(gestureID: gestureID)
            return
        }

        let shouldFlushImmediately = scroll.canFlushImmediately
        if shouldFlushImmediately {
            scroll.canFlushImmediately = false
        }
        activeRemoteScroll = scroll

        if shouldFlushImmediately {
            flushRemoteScroll(
                gestureID: gestureID,
                reopenImmediateWindowWhenEmpty: false
            )
        }
        if let activeScroll = activeRemoteScroll,
           activeScroll.gestureID == gestureID {
            scheduleRemoteScrollFlush(for: activeScroll)
        }
    }

    func endRemoteScroll(gestureID: UUID) {
        guard var scroll = activeRemoteScroll,
              scroll.gestureID == gestureID,
              remoteScrollIsCurrent(scroll) else {
            cancelRemoteScroll(gestureID: gestureID)
            return
        }
        remoteScrollFlushTask?.cancel()
        remoteScrollFlushTask = nil
        scroll.isEnding = true
        activeRemoteScroll = scroll
        flushRemoteScroll(gestureID: gestureID)
    }

    func cancelRemoteScroll(gestureID: UUID) {
        guard activeRemoteScroll?.gestureID == gestureID
                || remoteInputQueue.contains(where: { $0.scrollGestureID == gestureID }) else {
            return
        }
        revokeRemoteScrollSendAuthorization()
        discardActiveRemoteScroll(removingQueuedPackets: false)
        remoteInputQueue.removeAll(where: { $0.scrollGestureID != nil })
    }

    func discardPendingRemoteScrolls() {
        revokeRemoteScrollSendAuthorization()
        discardActiveRemoteScroll(removingQueuedPackets: false)
        remoteInputQueue.removeAll(where: { $0.scrollGestureID != nil })
    }

    private func discardQueuedRemoteInputsForInactiveLifecycle() {
        revokeRemoteScrollSendAuthorization()
        revokeRemoteInputLifecycleSendAuthorization()
        remoteInputGeneration = UUID()
        remoteInputDrainTask?.cancel()
        remoteInputDrainTask = nil
        discardActiveRemoteScroll(removingQueuedPackets: false)
        remoteInputQueue.removeAll(keepingCapacity: false)
    }

    private func suspendRemoteInputForApplicationLifecycle() {
        guard !applicationInputIsSuspended else { return }
        applicationInputIsSuspended = true
        cancelFocusedWindowResize()
        discardQueuedRemoteInputsForInactiveLifecycle()
        clearRemoteKeyboardFocus()
    }

    private func scheduleRemoteScrollFlush(for scroll: ActiveRemoteScroll) {
        guard remoteScrollFlushTask == nil,
              activeRemoteScroll?.gestureID == scroll.gestureID else { return }
        let gestureID = scroll.gestureID
        let inputGeneration = scroll.inputGeneration
        remoteScrollFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.remoteScrollFlushInterval)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  inputGeneration == self.remoteInputGeneration else { return }
            self.remoteScrollFlushTask = nil
            self.flushRemoteScroll(
                gestureID: gestureID,
                reopenImmediateWindowWhenEmpty: true
            )
        }
    }

    private func flushRemoteScroll(
        gestureID: UUID,
        reopenImmediateWindowWhenEmpty: Bool = false
    ) {
        guard var scroll = activeRemoteScroll,
              scroll.gestureID == gestureID,
              remoteScrollIsCurrent(scroll) else {
            cancelRemoteScroll(gestureID: gestureID)
            return
        }

        let finalizing = scroll.isEnding
        guard let delta = scroll.accumulator.takeNextPacket(finalizing: finalizing) else {
            if finalizing {
                activeRemoteScroll = nil
            } else {
                if reopenImmediateWindowWhenEmpty {
                    scroll.canFlushImmediately = true
                }
                activeRemoteScroll = scroll
            }
            return
        }

        activeRemoteScroll = scroll
        enqueueRemoteInput(
            .scroll(
                anchor: scroll.anchor,
                deltaX: delta.x,
                deltaY: delta.y
            ),
            pointerIntentID: scroll.pointerIntentID,
            viewerVideoSize: scroll.protocolVideoSize,
            scrollGestureID: scroll.gestureID,
            sendAuthorization: scroll.sendAuthorization
        )

        guard activeRemoteScroll?.gestureID == gestureID else { return }
        if finalizing {
            if scroll.accumulator.hasPacket(finalizing: true) {
                scheduleRemoteScrollFlush(for: scroll)
            } else {
                activeRemoteScroll = nil
            }
        } else {
            scheduleRemoteScrollFlush(for: scroll)
        }
    }

    private func remoteScrollIsCurrent(_ scroll: ActiveRemoteScroll) -> Bool {
        scroll.sessionGeneration == sessionGeneration
            && scroll.inputGeneration == remoteInputGeneration
            && scroll.capability == remoteInputCapability
            && scroll.authorization === remoteInputAuthorization
            && scroll.authorization.isValid
            && scroll.sendAuthorization === remoteScrollSendAuthorization
            && scroll.sendAuthorization.isValid
            && isRemoteScrollAvailable
    }

    private func discardActiveRemoteScroll(removingQueuedPackets: Bool) {
        remoteScrollFlushTask?.cancel()
        remoteScrollFlushTask = nil
        if removingQueuedPackets, let gestureID = activeRemoteScroll?.gestureID {
            remoteInputQueue.removeAll(where: { $0.scrollGestureID == gestureID })
        }
        activeRemoteScroll = nil
    }

    private func currentRemoteScrollSendAuthorization() -> WebRTCInputSendAuthorization {
        if let remoteScrollSendAuthorization,
           remoteScrollSendAuthorization.isValid {
            return remoteScrollSendAuthorization
        }
        let authorization = WebRTCInputSendAuthorization()
        remoteScrollSendAuthorization = authorization
        return authorization
    }

    private func revokeRemoteScrollSendAuthorization() {
        remoteScrollSendAuthorization?.revoke()
        remoteScrollSendAuthorization = nil
    }

    private func currentRemoteInputLifecycleSendAuthorization()
        -> WebRTCInputSendAuthorization {
        if let remoteInputLifecycleSendAuthorization,
           remoteInputLifecycleSendAuthorization.isValid {
            return remoteInputLifecycleSendAuthorization
        }
        let authorization = WebRTCInputSendAuthorization()
        remoteInputLifecycleSendAuthorization = authorization
        return authorization
    }

    private func revokeRemoteInputLifecycleSendAuthorization() {
        guard let authorization = remoteInputLifecycleSendAuthorization else {
            return
        }
        authorization.revoke()
        remoteInputLifecycleSendAuthorization = nil
    }

    private static func remoteInputVideoSize(
        from size: CGSize
    ) -> WebRTCInputVideoSize? {
        guard size.width.isFinite,
              size.height.isFinite else { return nil }
        let width = size.width.rounded()
        let height = size.height.rounded()
        guard (2 ... 32_768).contains(width),
              (2 ... 32_768).contains(height) else { return nil }
        return WebRTCInputVideoSize(width: Int(width), height: Int(height))
    }

    private func beginRemotePointerIntent() -> UInt64 {
        latestPointerIntentID &+= 1
        if latestPointerIntentID == 0 { latestPointerIntentID = 1 }
        clearRemoteKeyboardFocus()
        return latestPointerIntentID
    }

    private func retireRemotePointerIntentPreservingKeyboardFocus() {
        latestPointerIntentID &+= 1
        if latestPointerIntentID == 0 { latestPointerIntentID = 1 }
        remoteInputQueue.removeAll(where: {
            $0.focusedWindowResizeOperation == nil && $0.action.isOrdinaryPointerAction
        })
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
        pointerIntentID: UInt64? = nil,
        viewerVideoSize: WebRTCInputVideoSize? = nil,
        scrollGestureID: UUID? = nil,
        sendAuthorization: WebRTCInputSendAuthorization? = nil,
        focusedWindowResizeInteractionID: UUID? = nil,
        focusedWindowResizeOperation: FocusedWindowResizePendingOperation? = nil
    ) {
        let hasResizeMetadata = focusedWindowResizeInteractionID != nil
            || focusedWindowResizeOperation != nil
        guard action.isFocusedWindowResizeAction == hasResizeMetadata,
              !hasResizeMetadata
                || (focusedWindowResizeInteractionID != nil
                    && focusedWindowResizeOperation?.matches(action) == true) else {
            cancelFocusedWindowResize()
            return
        }
        guard let capability = remoteInputCapability,
              let authorization = remoteInputAuthorization,
              authorization.isValid,
              isRemoteInputAvailable else {
            return
        }
        let sendAuthorization = sendAuthorization
            ?? currentRemoteInputLifecycleSendAuthorization()
        guard sendAuthorization.isValid else { return }
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
                pointerIntentID: pointerIntentID,
                viewerVideoSize: viewerVideoSize,
                scrollGestureID: scrollGestureID,
                sendAuthorization: sendAuthorization,
                focusedWindowResizeInteractionID: focusedWindowResizeInteractionID,
                focusedWindowResizeOperation: focusedWindowResizeOperation
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
        case .tap, .primaryDrag, .scroll,
             .requestFocusedWindowResizeTarget,
             .selectWindowForResize,
             .commitFocusedWindowResize:
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
                  queued.sendAuthorization?.isValid != false,
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
                guard !Task.isCancelled,
                      queued.authorization.isValid,
                      queued.sendAuthorization?.isValid != false else { continue }
                let requestScope = RemoteInputRequestScope(
                    sessionGeneration: queued.sessionGeneration,
                    peer: peer,
                    capability: queued.capability
                )
                let requestID = try await sendRemoteInput(
                    queued.action,
                    viewerVideoSize: queued.viewerVideoSize,
                    peer: peer,
                    capability: queued.capability,
                    authorization: queued.authorization,
                    sendAuthorization: queued.sendAuthorization
                )
                guard !Task.isCancelled,
                      inputGeneration == remoteInputGeneration,
                      queued.sessionGeneration == sessionGeneration,
                      self.peer === peer,
                      queued.capability == remoteInputCapability,
                      queued.authorization === remoteInputAuthorization,
                      queued.authorization.isValid,
                      queued.sendAuthorization?.isValid != false else {
                    // A non-cooperative send may return after a replacement peer has restarted
                    // request IDs. Its bounded tombstone remains safe because the scope is part of
                    // the key, but it must never consume bare-ID early feedback from a replacement.
                    let requestScopeIsCurrent = queued.sessionGeneration == sessionGeneration
                        && self.peer === peer
                        && queued.capability == remoteInputCapability
                    if let operation = queued.focusedWindowResizeOperation {
                        retireFocusedWindowResizeRequestID(
                            requestID,
                            operation: operation,
                            requestScope: requestScope
                        )
                    }
                    guard requestScopeIsCurrent else { continue }
                    if queued.focusedWindowResizeOperation != nil {
                        if let feedback = earlyRemoteInputFeedback.removeValue(
                            forKey: requestID
                        ) {
                            handleRemoteInputFeedback(feedback)
                        }
                    } else {
                        earlyRemoteInputFeedback.removeValue(forKey: requestID)
                    }
                    continue
                }
                pendingRemoteInputs[requestID] = PendingRemoteInput(
                    kind: PendingRemoteInputKind(
                        queued.action,
                        focusedWindowResizeInteractionID:
                            queued.focusedWindowResizeInteractionID,
                        focusedWindowResizeOperation:
                            queued.focusedWindowResizeOperation
                    ),
                    pointerIntentID: queued.pointerIntentID,
                    sendAuthorization: queued.sendAuthorization,
                    requestScope: requestScope
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
                if queued.sendAuthorization?.isValid == false {
                    continue
                }
                if let transportError = error as? WebRTCTransportError,
                   transportError == .invalidInputRequest {
                    if queued.focusedWindowResizeOperation != nil {
                        cancelFocusedWindowResize()
                        lastDiagnostic = "The focused-window resize request was not valid."
                    } else {
                        clearRemoteKeyboardFocus()
                        remoteInputQueue.removeAll(where: { $0.action.requiresRemoteFocus })
                        lastDiagnostic = "The remote input action was not valid."
                    }
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
        viewerVideoSize: WebRTCInputVideoSize?,
        peer: WebRTCPeer,
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization,
        sendAuthorization: WebRTCInputSendAuthorization?
    ) async throws -> UInt64 {
        #if DEBUG
        if let debugRemoteInputSender {
            return try await debugRemoteInputSender(
                peer,
                action,
                viewerVideoSize,
                capability,
                authorization,
                sendAuthorization
            )
        }
        #endif
        return try await peer.sendInput(
            action,
            viewerVideoSize: viewerVideoSize,
            capability: capability,
            authorization: authorization,
            sendAuthorization: sendAuthorization
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
            guard let audioTransactionDeviceBinding =
                    newPeer.iOSAudioTransactionDeviceBinding,
                  audioLifecycle.bindIOSAudioTransactionDevice(
                    audioTransactionDeviceBinding
                  ) else {
                _ = await newPeer.close(reason: .protocolError)
                throw WebRTCTransportError.nativeFailure(
                    "The native iPhone audio transaction authority could not bind the current peer."
                )
            }
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
            startAudioTransactionEventLoop(
                peer: newPeer,
                generation: generation
            )
            let newPeerIdentity = ObjectIdentifier(newPeer)
            await newPeer.installIPhoneMicrophoneTransportSuspensionHandlers(
                preparation: { [weak self] retirementContext in
                    guard let self else { return nil }
                    return prepareIPhoneMicrophoneForTransportSuspension(
                        retirementContext: retirementContext,
                        expectedPeerIdentity: newPeerIdentity,
                        expectedSessionGeneration: generation
                    )
                },
                completion: {
                    [weak self] retirementContext,
                    outputOnlyToken,
                    succeeded in
                    guard let self else { return }
                    completeIPhoneMicrophoneTransportSuspension(
                        retirementContext: retirementContext,
                        outputOnlyToken: outputOnlyToken,
                        succeeded: succeeded,
                        expectedPeerIdentity: newPeerIdentity,
                        expectedSessionGeneration: generation
                    )
                }
            )
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

    private func startAudioTransactionEventLoop(
        peer sourcePeer: WebRTCPeer,
        generation: UUID
    ) {
        precondition(audioTransactionEventTask == nil)
        installAudioTransactionCallbacks(
            peer: sourcePeer,
            generation: generation
        )
        let events = sourcePeer.iOSAudioTransactionEvents
        audioTransactionEventTask = Task { [weak self] in
            var teardownResult: Bool?
            for await event in events {
                guard !Task.isCancelled else { return false }
                if let result = self?.handleAudioTransactionEvent(
                    event,
                    peer: sourcePeer,
                    generation: generation
                ) {
                    teardownResult = result
                }
            }
            if let teardownResult { return teardownResult }
            guard !Task.isCancelled,
                  let self,
                  generation == sessionGeneration,
                  peer === sourcePeer,
                  hasActiveSession else {
                return false
            }
            failSession(
                "The native iPhone audio transaction stream closed.",
                generation: generation
            )
            return false
        }
    }

    private func installAudioTransactionCallbacks(
        peer sourcePeer: WebRTCPeer,
        generation: UUID
    ) {
        audioLifecycle.onPlayoutRecoveryTransactionStagingRequested = {
            [weak self, weak sourcePeer] context, inputRequired in
            guard let self, let sourcePeer,
                  generation == self.sessionGeneration,
                  self.peer === sourcePeer else {
                return nil
            }
            let authorization = WebRTCIOSPlayoutRecoveryAuthorization(
                transaction: context
            )
            guard sourcePeer.stageIOSPlayoutRecoveryTransaction(
                authorization: authorization,
                inputRequired: inputRequired
            ) else {
                authorization.revoke()
                return nil
            }
            return authorization
        }
        audioLifecycle.onTransactionalPlaybackRecoveryRequested = {
            [weak self, weak sourcePeer] transaction in
            guard let self, let sourcePeer,
                  generation == self.sessionGeneration,
                  self.peer === sourcePeer else {
                transaction.authorization.revoke()
                return
            }
            self.beginIOSPlayoutProof(
                transaction: transaction,
                postCallRecoveryMilestone:
                    self.audioLifecycle
                        .postCallMicrophoneRecoveryMilestone
            )
        }
        audioLifecycle.onAudioTransactionDrainRequested = {
            [weak self, weak sourcePeer] request in
            guard let self, let sourcePeer,
                  generation == self.sessionGeneration,
                  self.peer === sourcePeer else {
                return false
            }
            return sourcePeer.requestIOSAudioCategoryDrain(
                transaction: request.operation.nativeContext,
                tagGeneration: request.tagGeneration
            )
        }
    }

    private func handleAudioTransactionEvent(
        _ event: WebRTCIOSAudioTransactionEvent,
        peer sourcePeer: WebRTCPeer,
        generation: UUID
    ) -> Bool? {
        switch event {
        case .observation(let receipt):
            guard generation == sessionGeneration,
                  peer === sourcePeer else { return nil }
            audioLifecycle.consumeIOSAudioCategoryObservation(receipt)
            return nil
        case .drain(let receipt):
            guard generation == sessionGeneration,
                  peer === sourcePeer else { return nil }
            audioLifecycle.consumeIOSAudioCategoryDrain(receipt)
            return nil
        case .deviceTeardown(let receipt):
            // Teardown is intentionally accepted after sessionGeneration rotates and `peer`
            // clears. The replacement session awaits this task before binding its own device.
            return audioLifecycle
                .consumeIOSAudioTransactionDeviceTeardown(receipt)
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
                    markTransportUncertain("Recovering secure media")
                    await recoveryCoordinator?.iceStateChanged(.disconnected)
                }
            }

        case .iceGatheringStateChanged:
            break

        case .dataChannelStateChanged(let state):
            if state == .open {
                isControlChannelReady = true
                await markViewerTransportHealthyIfPossible(.connected)
            } else if state == .closing || state == .closed {
                // The Mac also stops capture on these states. A recovered channel therefore
                // requires a fresh acknowledged Show instead of silently resuming video.
                markTransportUncertain("Recovering secure media")
                isControlChannelReady = false
                await recoveryCoordinator?.iceStateChanged(.failed)
            } else {
                isControlChannelReady = false
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

        case .screenMediaSuspensionReceived(let notice):
            receiveScreenMediaSuspension(
                notice,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
            )

        case .screenMediaMarkerReadyReceived(let ready):
            receiveScreenMediaMarkerReady(
                ready,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
            )

        case .screenMediaResumeReadyReceived(let ready):
            receiveScreenMediaResumeReady(
                ready,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
            )

        case .screenMediaResumedAcknowledgementReceived(
            let acknowledgement,
            inputAuthorization: let inputAuthorization
        ):
            receiveScreenMediaResumedAcknowledgement(
                acknowledgement,
                inputAuthorization: inputAuthorization,
                sourcePeer: sourcePeer,
                sourceGeneration: generation
            )

        case .screenMediaSuspensionInvalidated(let reason):
            cancelScreenMediaViewerSuspension(
                reason: reason,
                notifyPeer: false
            )

        case .screenMediaCoveredAcknowledgementReceived,
             .screenMediaMarkerPresentationReceived,
             .screenMediaResumeRequestReceived,
             .screenMediaEncoderResumeProbeEvent:
            // Host-only events. A viewer must never advance from them.
            break

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

        case .statistics(let snapshot, wholePeerReportWasCollected: _):
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
            if crossedHealthyBoundary {
                markTransportUncertain("Recovering secure media")
                isPeerConnected = false
                await recoveryCoordinator?.iceStateChanged(.disconnected)
            } else {
                isPeerConnected = false
                stateText = "Connecting media"
            }
        case .connected:
            isConnecting = false
            isPeerConnected = true
            await markViewerTransportHealthyIfPossible(.connected)
        case .disconnected:
            retireIOSHostedCallPlayoutAttempt()
            markTransportUncertain("Recovering secure media")
            isPeerConnected = false
            await recoveryCoordinator?.iceStateChanged(.disconnected)
        case .failed:
            retireIOSHostedCallPlayoutAttempt()
            markTransportUncertain("Recovering secure media")
            isPeerConnected = false
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
        refreshScreenLivenessDiagnostic()
        await sendScreenClientDiagnosticsHeartbeat(
            through: sourcePeer,
            generation: generation
        )
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
        let expectedMicrophoneOperationGeneration =
            microphoneOperationGeneration
        let expectedAuthorizationIdentity =
            ObjectIdentifier(authorization)
        let expectedRecordingGeneration =
            authorization.recordingGeneration
        let expectedMicrophoneCallDisposition =
            currentMicrophoneCallDisposition
        let unprovenProgressBinding =
            WorldwideRawMicrophoneMissingStatisticsBinding(
                sessionGeneration: generation,
                peerIdentity: ObjectIdentifier(sourcePeer),
                transportAuthorizationGeneration:
                    expectedTransportAuthorizationGeneration,
                audioPolicyGeneration:
                    expectedAudioPolicyGeneration,
                microphoneOperationGeneration:
                    expectedMicrophoneOperationGeneration,
                authorizationIdentity:
                    expectedAuthorizationIdentity,
                recordingGeneration:
                    expectedRecordingGeneration,
                microphoneCallDisposition:
                    expectedMicrophoneCallDisposition
            )
        let exactStatistics =
            await readIPhoneMicrophoneSenderStatistics(
                from: sourcePeer
            )
        guard automaticMicrophoneEligibleSessionGeneration
                == generation,
              generation == sessionGeneration,
              peer === sourcePeer,
              audioPolicyGeneration
                == expectedAudioPolicyGeneration,
              transportAuthorizationGeneration
                == expectedTransportAuthorizationGeneration,
              microphoneOperationGeneration
                == expectedMicrophoneOperationGeneration,
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
                == expectedRecordingGeneration,
              currentMicrophoneCallDisposition
                == expectedMicrophoneCallDisposition else {
            return
        }

        guard let exactStatistics else {
            observeUnprovenRawMicrophoneProgress(
                binding: unprovenProgressBinding,
                generation: generation
            )
            return
        }

        guard authorization.recordingGeneration
                == exactStatistics.sender.recordingGeneration,
              exactStatistics.sender.recordingGeneration
                == exactStatistics.sender
                    .approvedRecordingGeneration,
              exactStatistics.sender
                .captureRouteIsBuiltInMicrophone,
              exactStatistics.sender
                .captureRouteProofGeneration > 0 else {
            rawMicrophoneContinuityTracker.reset()
            observeUnprovenRawMicrophoneProgress(
                binding: unprovenProgressBinding,
                generation: generation
            )
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
                expectedMicrophoneCallDisposition != .inactive,
            macHostedCallEvidenceAdmitted:
                expectedMicrophoneCallDisposition == .macHosted,
            transportIsHealthy: true,
            statistics: exactStatistics
        )
        switch rawMicrophoneContinuityTracker.observe(sample) {
        case .waiting:
            observeUnprovenRawMicrophoneProgress(
                binding: unprovenProgressBinding,
                generation: generation
            )
        case .satisfied(let oracle):
            worldwideRawMicrophoneOracle = oracle
            rawMicrophoneMissingStatisticsTracker.reset()
            microphoneAutomaticRecoveryConsumedBinding = nil
        case .stalled:
            worldwideRawMicrophoneOracle = nil
            rawMicrophoneMissingStatisticsTracker.reset()
            recoverFromStalledIPhoneMicrophone(generation: generation)
        case .rejected:
            observeUnprovenRawMicrophoneProgress(
                binding: unprovenProgressBinding,
                generation: generation
            )
        }
    }

    private func observeUnprovenRawMicrophoneProgress(
        binding: WorldwideRawMicrophoneMissingStatisticsBinding,
        generation: UUID
    ) {
        revokePublishedRawMicrophoneOracle()
        if rawMicrophoneMissingStatisticsTracker.observe(
            binding: binding,
            observedAt:
                rawMicrophoneMissingStatisticsObservationUptime()
        ) == .stalled {
            rawMicrophoneContinuityTracker.reset()
            recoverFromStalledIPhoneMicrophone(
                generation: generation
            )
        }
    }

    private func recoverFromStalledIPhoneMicrophone(generation: UUID) {
        #if DEBUG
        debugStalledIPhoneMicrophoneRecoveryObserver?()
        #endif
        guard generation == sessionGeneration,
              microphoneIntentEnabled,
              isMicrophoneSending,
              let sourcePeer = peer else { return }

        let recoveryBinding = MicrophoneAutomaticRecoveryBinding(
            sessionGeneration: generation,
            peerIdentity: ObjectIdentifier(sourcePeer),
            transportAuthorizationGeneration:
                transportAuthorizationGeneration
        )

        if microphoneAutomaticRecoveryConsumedBinding
            == recoveryBinding {
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

        microphoneAutomaticRecoveryConsumedBinding = recoveryBinding
        microphoneAdmissionRecoveryPendingBinding = recoveryBinding
        microphoneAdmissionRecoveryProofAttemptID = nil
        guard audioLifecycle
                .requestAutomaticRuntimeMicrophoneRecovery() else {
            if microphoneAdmissionRecoveryPendingBinding
                == recoveryBinding {
                microphoneAdmissionRecoveryPendingBinding = nil
                microphoneAdmissionRecoveryProofAttemptID = nil
            }
            if microphoneAutomaticRecoveryConsumedBinding
                == recoveryBinding {
                microphoneAutomaticRecoveryConsumedBinding = nil
            }
            return
        }
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

    private func rawMicrophoneMissingStatisticsObservationUptime()
        -> TimeInterval {
        #if DEBUG
        if let debugRawMicrophoneMissingStatisticsUptimeClock {
            return debugRawMicrophoneMissingStatisticsUptimeClock()
        }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func revokePublishedRawMicrophoneOracle() {
        worldwideRawMicrophoneOracle = nil
    }

    private func clearRawMicrophoneOracle() {
        rawMicrophoneContinuityTracker.reset()
        revokePublishedRawMicrophoneOracle()
    }

    private func invalidateRawMicrophoneOracle() {
        clearRawMicrophoneOracle()
        rawMicrophoneMissingStatisticsTracker.reset()
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
        microphoneAutomaticRecoveryConsumedBinding = nil
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
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
        microphoneNativeTeardownID = nil
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
        microphoneTransportSuspensionBinding = nil
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
        let oldAudioTransactionEventTask =
            audioTransactionEventTask
        let precedingRetirement = sessionRetirementTask
        sessionRetirementGeneration = UUID()
        #if DEBUG
        let beforeRetiredPeerClose = debugBeforeRetiredPeerClose
        #endif
        sessionTask = nil
        peerEventTask = nil
        audioTransactionEventTask = nil
        audioPlayoutProofTask = nil
        signaling = nil
        peer = nil
        iceIsConnected = false
        nextICERestartRequestID = 1

        let retirementTask = Task { @MainActor in
            let precedingRetirementSucceeded =
                await precedingRetirement?.value ?? true
            #if DEBUG
            await beforeRetiredPeerClose?()
            #endif
            let peerRetirementSucceeded: Bool
            if let oldPeer {
                peerRetirementSucceeded = await oldPeer.close(reason: reason)
            } else {
                oldAudioTransactionEventTask?.cancel()
                peerRetirementSucceeded = true
            }
            // Native close synchronously yields teardown and then finishes the stream. Waiting for
            // this consumer proves the old reducer namespace was reset before admission returns.
            let audioTransactionRetirementSucceeded =
                await oldAudioTransactionEventTask?.value
                    ?? (oldPeer == nil)
            await oldRecoveryCoordinator?.cancel()
            await oldSignaling?.close()
            return precedingRetirementSucceeded
                && peerRetirementSucceeded
                && audioTransactionRetirementSucceeded
        }
        sessionRetirementTask = retirementTask
    }

    private func resetPublishedSessionState() {
        ordinaryPlayoutLivenessTracker.reset()
        microphoneAutomaticRecoveryConsumedBinding = nil
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
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
        microphoneTransportSuspensionBinding = nil
        routeText = "Unknown"
        iceStateText = "Inactive"
        remoteDisplayName = "Mac mini"
        invitationExpiresAt = nil
        statistics = nil
        screenClientDiagnosticsDeliveryText = "Idle"
        advanceScreenLivenessGeneration(clearRenderObservation: true)
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
        transaction: WorldwideAudioRecoveryTransaction,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone? = nil
    ) -> Task<Void, Never>? {
        let task = beginIOSPlayoutProof(
            requestRecovery: true,
            postCallRecoveryMilestone: postCallRecoveryMilestone,
            recoveryTransaction: transaction
        )
        if task == nil {
            audioLifecycle.updateTransactionalRuntimePlayout(
                transaction: transaction,
                isReady: false,
                failureMessage:
                    "The iPhone 48 kHz stereo render path did not start.",
                diagnostic:
                    "The exact recovery proof could not start on the current peer."
            )
        }
        return task
    }

    @discardableResult
    private func beginIOSPlayoutProof(
        requestRecovery: Bool,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone? = nil,
        categoryProofClaim:
            WorldwideAudioCategoryProofClaim? = nil,
        recoveryTransaction:
            WorldwideAudioRecoveryTransaction? = nil
    ) -> Task<Void, Never>? {
        guard !ordinaryIOSPlayoutProofIsSuppressedByHostedCall else {
            recoveryTransaction?.authorization.revoke()
            return nil
        }
        let pendingMicrophoneRecoveryIsCurrent =
            microphoneAdmissionRecoveryPendingBinding
                == currentMicrophoneAutomaticRecoveryBinding()
        if recoveryTransaction == nil,
           pendingMicrophoneRecoveryIsCurrent,
           categoryProofClaim == nil,
           let currentAttempt = iosPlayoutProofAttempt,
           microphoneAdmissionRecoveryProofAttemptID
                == currentAttempt.proofAttemptID,
           iosPlayoutProofAttemptIsOwned(currentAttempt) {
            // A remote-track/statistics refresh is observational. It must not replace the exact
            // recovery-backed proof that owns microphone readmission.
            return audioPlayoutProofTask
        }
        retireIOSPlayoutRecoveryAttempt()
        audioPlayoutProofTask?.cancel()
        audioPlayoutProofTask = nil
        guard let proofPeer = peer else {
            recoveryTransaction?.authorization.revoke()
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

        let requiresRecovery = requestRecovery
            || recoveryTransaction != nil
            || audioPolicyRequiresFreshRecovery
            || pendingMicrophoneRecoveryIsCurrent
        #if DEBUG
        let permitsLegacyUntransactionalRecovery =
            debugIOSPlayoutRecoveryRequester != nil
        #else
        let permitsLegacyUntransactionalRecovery = false
        #endif
        if requiresRecovery,
           recoveryTransaction == nil,
           !permitsLegacyUntransactionalRecovery {
            _ = audioLifecycle.requestTransactionalRuntimePlayoutRecovery(
                requiresRemoteAudio: !pendingMicrophoneRecoveryIsCurrent
            )
            return nil
        }
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
            recoveryTransaction: recoveryTransaction,
            stage: requiresRecovery ? .awaitingRecoveryBaseline : .awaitingInitialFloor
        )
        iosPlayoutProofAttempt = attempt
        if pendingMicrophoneRecoveryIsCurrent {
            microphoneAdmissionRecoveryProofAttemptID =
                attempt.proofAttemptID
        }
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

                let authorization: WebRTCIOSPlayoutRecoveryAuthorization
                if let recoveryTransaction {
                    authorization = recoveryTransaction.authorization
                } else {
                    #if DEBUG
                    guard debugIOSPlayoutRecoveryRequester != nil else {
                        failIOSPlayoutProofTimeout(attempt)
                        return
                    }
                    authorization = WebRTCIOSPlayoutRecoveryAuthorization()
                    #else
                    failIOSPlayoutProofTimeout(attempt)
                    return
                    #endif
                }
                if let recoveryTransaction {
                    guard recoveryTransaction.authorization === authorization,
                          authorization.transaction
                            == recoveryTransaction.operation.nativeContext,
                          authorization.stagedTransactionTagGeneration != nil else {
                        authorization.revoke()
                        failIOSPlayoutProofTimeout(attempt)
                        return
                    }
                }
                attempt.recoveryAuthorization = authorization
                attempt.stage = .awaitingRecoveryAuthorization
                audioPlayoutRecoveryAuthorization = authorization

                guard iosPlayoutProofAttemptIsOwned(attempt),
                      attempt.recoveryAuthorization === authorization,
                      audioPlayoutRecoveryAuthorization === authorization else {
                    authorization.revoke()
                    return
                }
                guard await requestIOSPlayoutRecovery(
                    on: proofPeer,
                    authorization: authorization
                ) else {
                    failIOSPlayoutProofTimeout(attempt)
                    return
                }
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
    ) async -> Bool {
        #if DEBUG
        if let debugIOSPlayoutRecoveryRequester {
            await debugIOSPlayoutRecoveryRequester(proofPeer, authorization)
            return true
        }
        #endif
        return await proofPeer.requestIOSPlayoutRecovery(
            authorization: authorization
        )
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
        failPendingMicrophoneAdmissionRecoveryIfOwned(
            by: attempt,
            message:
                "The iPhone microphone audio path did not recover in time. Tap Retry iPhone Microphone."
        )
        let failureMessage =
            "The iPhone 48 kHz stereo render path did not start."
        let diagnostic =
            "RemoteIO produced no verified playout callback within two seconds."
        if let recoveryTransaction = attempt.recoveryTransaction {
            audioLifecycle.updateTransactionalRuntimePlayout(
                transaction: recoveryTransaction,
                isReady: false,
                failureMessage: failureMessage,
                diagnostic: diagnostic
            )
            retireIOSPlayoutRecoveryAttempt(attempt)
        } else {
            retireIOSPlayoutRecoveryAttempt(attempt)
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                failureMessage: failureMessage,
                diagnostic: diagnostic,
                categoryProofClaim: attempt.categoryProofClaim
            )
        }
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
            if attempt.recoveryTransaction != nil {
                guard let terminalReceipt = authorization.terminalReceipt else {
                    return false
                }
                if !attempt.nativeRecoveryReceiptWasConsumed {
                    audioLifecycle.consumeIOSPlayoutRecoveryReceipt(
                        terminalReceipt
                    )
                    attempt.nativeRecoveryReceiptWasConsumed = true
                }
                guard terminalReceipt.outcome == .accepted,
                      terminalReceipt.policyMatchesRequestedTarget else {
                    return failIOSPlayoutProof(
                        attempt,
                        diagnostics: diagnostics,
                        diagnosticOverride:
                            "Native recovery rejected or installed a policy that did not match its exact transaction target."
                    )
                }
            } else {
                guard authorization.terminalGeneration
                        == authorization.generation,
                      authorization.terminalOutcome == .accepted else {
                    // Legacy proof-only test attempts carry no reducer identity. They may observe
                    // terminal capability state, but can never synthesize a native receipt.
                    return false
                }
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

        let completedMicrophoneAdmissionRecovery =
            completePendingMicrophoneAdmissionRecoveryIfOwned(
                by: attempt
            )
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
        if let recoveryTransaction = attempt.recoveryTransaction {
            audioLifecycle.updateTransactionalRuntimePlayout(
                transaction: recoveryTransaction,
                isReady: true
            )
            retireIOSPlayoutRecoveryAttempt(attempt)
        } else {
            retireIOSPlayoutRecoveryAttempt(attempt)
            audioLifecycle.updateRuntimePlayout(
                isReady: true,
                categoryProofClaim: attempt.categoryProofClaim
            )
        }
        if completedMicrophoneAdmissionRecovery {
            // Runtime-proof publication normally reconciles synchronously. Redrive explicitly as
            // well so a lifecycle observer that coalesces an unchanged snapshot cannot strand the
            // proven admission in "Starting".
            reconcileIPhoneMicrophone(for: audioLifecycle.snapshot)
        }
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
        failPendingMicrophoneAdmissionRecoveryIfOwned(
            by: attempt,
            message:
                "The iPhone microphone audio path could not recover automatically. Tap Retry iPhone Microphone."
        )
        if let recoveryTransaction = attempt.recoveryTransaction {
            audioLifecycle.updateTransactionalRuntimePlayout(
                transaction: recoveryTransaction,
                isReady: false,
                failureMessage: message,
                diagnostic: diagnostic
            )
            retireIOSPlayoutRecoveryAttempt(attempt)
        } else {
            retireIOSPlayoutRecoveryAttempt(attempt)
            audioLifecycle.updateRuntimePlayout(
                isReady: false,
                failureMessage: message,
                diagnostic: diagnostic,
                categoryProofClaim: attempt.categoryProofClaim
            )
        }
        return true
    }

    private func completePendingMicrophoneAdmissionRecoveryIfOwned(
        by attempt: IOSPlayoutProofAttempt
    ) -> Bool {
        guard let pendingBinding =
                microphoneAdmissionRecoveryPendingBinding,
              attempt.sessionGeneration == sessionGeneration,
              attempt.expectedPeer === peer,
              microphoneAdmissionRecoveryProofAttemptID
                == attempt.proofAttemptID,
              attempt.recoveryBaseline != nil,
              attempt.recoveryAuthorization?
                .hasAcceptedTerminalOutcome == true,
              pendingBinding
                == currentMicrophoneAutomaticRecoveryBinding() else {
            return false
        }
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
        microphoneAdmissionFailedSessionGeneration = nil
        microphoneStateText = "Starting"
        microphoneError = nil
        return true
    }

    private func failPendingMicrophoneAdmissionRecoveryIfOwned(
        by attempt: IOSPlayoutProofAttempt,
        message: String
    ) {
        guard let pendingBinding =
                microphoneAdmissionRecoveryPendingBinding,
              attempt.sessionGeneration == sessionGeneration,
              attempt.expectedPeer === peer,
              microphoneAdmissionRecoveryProofAttemptID
                == attempt.proofAttemptID,
              pendingBinding
                == currentMicrophoneAutomaticRecoveryBinding() else {
            return
        }
        microphoneAdmissionRecoveryPendingBinding = nil
        microphoneAdmissionRecoveryProofAttemptID = nil
        microphoneAdmissionFailedSessionGeneration = sessionGeneration
        microphoneStateText = "Unavailable"
        microphoneError = message
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
        if let attempt = screenMediaViewerAttempt,
           attempt.hideRequestKey == key,
           let exactSourcePeer = sourcePeer {
            handleScreenMediaHideAcknowledgement(
                acknowledgement,
                inputAuthorization: inputAuthorization,
                sourcePeer: exactSourcePeer,
                sourceGeneration: sourceGeneration,
                attempt: attempt
            )
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
                if activeScreenRequestID == pending.key.requestID {
                    activeScreenRequestID = nil
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
            activeScreenRequestID = pending.key.requestID
            isScreenVisible = true
            if recoveringScreenPresentationLease == pending.lease {
                recoveringScreenPresentationLease = nil
            }
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
            // `activeScreenRequestID` belongs to the acknowledged Show, while `pending.key` is
            // this later Hide. Comparing those unrelated command IDs leaves the old Show
            // correlation alive after capture has stopped.
            activeScreenRequestID = nil
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
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            preservingRecoveryPresentation: true
        )
        stateText = "Connected"
        // The authenticated, current-generation inactive acknowledgement is the recovery proof
        // that permits remote audio to leave the fail-closed mute gate.
        recordViewerTransportHealthProof()
        audioLifecycle.transportBecameHealthy()
        establishAutomaticIPhoneMicrophoneIntentIfEligible()
        continueIPhoneMicrophoneEnablementIfPossible()
        await recoveryCoordinator?.iceStateChanged(.connected)
        scheduleScreenPresentationRecoveryIfNeeded()
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
              let peer,
              feedback.screenRequestID == capability.screenRequestID,
              feedback.inputSessionID == capability.inputSessionID else {
            invalidateRemoteInputState()
            return
        }
        let requestScope = RemoteInputRequestScope(
            sessionGeneration: sessionGeneration,
            peer: peer,
            capability: capability
        )
        let retiredKey = RetiredFocusedWindowResizeRequestKey(
            requestID: feedback.id,
            requestScope: requestScope
        )
        if var retired = retiredFocusedWindowResizeRequests[retiredKey] {
            earlyRemoteInputFeedback.removeValue(forKey: feedback.id)
            guard !retired.didHandleFeedback else { return }
            retired.didHandleFeedback = true
            retiredFocusedWindowResizeRequests[retiredKey] = retired
            handleRetiredFocusedWindowResizeFeedback(
                feedback,
                operation: retired.operation
            )
            return
        }

        guard let pending = pendingRemoteInputs[feedback.id] else {
            guard earlyRemoteInputFeedback.count < 32 else {
                lastDiagnostic = "Remote input feedback arrived out of bounds."
                invalidateRemoteInputState()
                return
            }
            earlyRemoteInputFeedback[feedback.id] = feedback
            return
        }
        guard pending.requestScope == requestScope else {
            invalidateRemoteInputState()
            return
        }
        pendingRemoteInputs.removeValue(forKey: feedback.id)
        if let index = pendingRemoteInputOrder.firstIndex(of: feedback.id) {
            pendingRemoteInputOrder.remove(at: index)
        }
        guard pending.sendAuthorization?.isValid != false else { return }
        if case .pointer = pending.kind,
           pending.pointerIntentID != latestPointerIntentID {
            if feedback.result == .rejected,
               Self.isTerminalRemoteInputRejection(feedback.rejectionReason) {
                handleRemoteInputRejection(
                    feedback.rejectionReason,
                    screenFormatChanging: feedback.screenFormatChanging
                )
            }
            return
        }

        guard feedback.result == .accepted else {
            if case .focusedWindowResize(let interactionID, let operation) = pending.kind {
                handleRejectedFocusedWindowResizeFeedback(
                    feedback,
                    interactionID: interactionID,
                    operation: operation
                )
                handleRemoteInputRejection(
                    feedback.rejectionReason,
                    screenFormatChanging: feedback.screenFormatChanging
                )
                return
            }
            // The optional context distinguishes an owned format rebuild from genuine keyboard
            // throttling while keeping the established `.rateLimited` reason compatible.
            if !Self.preservesRemoteKeyboardFocus(
                after: feedback.rejectionReason,
                screenFormatChanging: feedback.screenFormatChanging,
                for: pending.kind
            ) {
                clearRemoteKeyboardFocus()
            }
            handleRemoteInputRejection(
                feedback.rejectionReason,
                screenFormatChanging: feedback.screenFormatChanging
            )
            return
        }

        switch pending.kind {
        case .pointer:
            guard feedback.windowResize == nil else {
                invalidateRemoteInputState()
                return
            }
            applyRemoteInputFocus(feedback.focus)

        case .keyboard(let generation):
            guard feedback.windowResize == nil else {
                invalidateRemoteInputState()
                return
            }
            guard focusedInputGeneration == generation else { return }
            applyRemoteInputFocus(feedback.focus)

        case .focusedWindowResize(let interactionID, let operation):
            handleAcceptedFocusedWindowResizeFeedback(
                feedback,
                interactionID: interactionID,
                operation: operation
            )
        }
    }

    /// A locally canceled resize can never restore its target or preview. Its authenticated host
    /// result still carries authoritative focus and terminal permission/session state, so retain
    /// only enough bounded correlation to apply those revocations exactly once.
    private func handleRetiredFocusedWindowResizeFeedback(
        _ feedback: WebRTCInputFeedback,
        operation: FocusedWindowResizePendingOperation
    ) {
        guard feedback.result == .accepted else {
            applyRetiredFocusedWindowResizeFocusRevocation(
                feedback.focus,
                expectedGeneration: operation.focusGeneration
            )
            handleRemoteInputRejection(
                feedback.rejectionReason,
                screenFormatChanging: feedback.screenFormatChanging
            )
            return
        }

        guard let resize = feedback.windowResize,
              Self.focusedWindowResizeTargetIsValid(resize.target),
              Self.focusedWindowResizeFeedback(resize, matches: operation),
              Self.focusedWindowResizeFocus(
                  feedback.focus,
                  matches: operation.focusGeneration
              ) else {
            revokeRemoteKeyboardFocusIfOwned(
                by: operation.focusGeneration
            )
            lastDiagnostic = "The Mac returned mismatched focused-window resize feedback."
            return
        }
        applyRetiredFocusedWindowResizeFocusRevocation(
            feedback.focus,
            expectedGeneration: operation.focusGeneration
        )
    }

    /// Late feedback for locally canceled resize work may revoke the exact focus generation that
    /// existed when the request was sent, but it can never install or resurrect editable focus.
    private func applyRetiredFocusedWindowResizeFocusRevocation(
        _ focus: WebRTCInputFocus,
        expectedGeneration: UInt64?
    ) {
        guard Self.focusedWindowResizeFocus(
            focus,
            matches: expectedGeneration
        ) else {
            revokeRemoteKeyboardFocusIfOwned(by: expectedGeneration)
            return
        }
        if case .none = focus {
            revokeRemoteKeyboardFocusIfOwned(by: expectedGeneration)
        }
    }

    private func revokeRemoteKeyboardFocusIfOwned(by generation: UInt64?) {
        guard focusedInputGeneration == generation else { return }
        clearRemoteKeyboardFocus()
    }

    private func handleAcceptedFocusedWindowResizeFeedback(
        _ feedback: WebRTCInputFeedback,
        interactionID: UUID,
        operation: FocusedWindowResizePendingOperation
    ) {
        guard var interaction = focusedWindowResizeState.interaction,
              interaction.id == interactionID,
              interaction.pending == operation else {
            return
        }
        guard focusedWindowResizeInteractionIsCurrent(interaction),
              let resize = feedback.windowResize,
              Self.focusedWindowResizeTargetIsValid(resize.target),
              Self.focusedWindowResizeFeedback(
                  resize,
                  matches: operation
              ),
              Self.focusedWindowResizeFocus(
                  feedback.focus,
                  matches: operation.focusGeneration
              ) else {
            clearRemoteKeyboardFocus()
            cancelFocusedWindowResize()
            lastDiagnostic = "The Mac returned mismatched focused-window resize feedback."
            return
        }

        applyRemoteInputFocus(feedback.focus)
        interaction.pending = nil
        interaction.target = resize.target
        focusedWindowResizeState = .active(interaction)
    }

    private func handleRejectedFocusedWindowResizeFeedback(
        _ feedback: WebRTCInputFeedback,
        interactionID: UUID,
        operation: FocusedWindowResizePendingOperation
    ) {
        guard let interaction = focusedWindowResizeState.interaction,
              interaction.id == interactionID,
              interaction.pending == operation else {
            return
        }
        if Self.focusedWindowResizeFocus(
            feedback.focus,
            matches: operation.focusGeneration
        ) {
            applyRemoteInputFocus(feedback.focus)
        } else {
            clearRemoteKeyboardFocus()
        }
        cancelFocusedWindowResize()
    }

    private static func focusedWindowResizeFeedback(
        _ feedback: WebRTCWindowResizeFeedback,
        matches operation: FocusedWindowResizePendingOperation
    ) -> Bool {
        switch operation {
        case .targetRequest:
            return feedback.kind == .targetAcquired
                && feedback.committedTargetGeneration == nil
        case .selection:
            return feedback.kind == .windowSelected
                && feedback.committedTargetGeneration == nil
        case .commit(_, let consumedTargetGeneration, _):
            return feedback.kind == .resizeCommitted
                && feedback.committedTargetGeneration == consumedTargetGeneration
                && feedback.target.generation != consumedTargetGeneration
        }
    }

    private static func focusedWindowResizeFocus(
        _ focus: WebRTCInputFocus,
        matches expectedGeneration: UInt64?
    ) -> Bool {
        switch focus {
        case .none:
            return true
        case .editable(let generation, secure: false):
            return expectedGeneration == generation
        case .editable(_, secure: true):
            return false
        }
    }

    private static func focusedWindowResizeTargetIsValid(
        _ target: WebRTCWindowResizeTarget
    ) -> Bool {
        let frame = target.normalizedFrame
        return target.generation != zeroUUID
            && frame.x.isFinite && frame.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.x >= 0 && frame.y >= 0
            && frame.width > 0 && frame.height > 0
            && frame.x + frame.width <= 1
            && frame.y + frame.height <= 1
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static func preservesRemoteKeyboardFocus(
        after rejection: WebRTCInputRejectionReason?,
        screenFormatChanging: Bool,
        for pendingKind: PendingRemoteInputKind
    ) -> Bool {
        guard rejection == .rateLimited,
              screenFormatChanging else { return false }
        if case .keyboard = pendingKind {
            return true
        }
        return false
    }

    private static func isTerminalRemoteInputRejection(
        _ rejection: WebRTCInputRejectionReason?
    ) -> Bool {
        switch rejection {
        case .accessibilityPermissionRequired,
             .eventPostingPermissionRequired,
             .inputDisabled,
             .staleSession,
             nil:
            true
        case .rateLimited, .injectionFailed, .invalidRequest, .invalidFocus:
            false
        }
    }

    private func handleRemoteInputRejection(
        _ reason: WebRTCInputRejectionReason?,
        screenFormatChanging: Bool = false
    ) {
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
            lastDiagnostic = screenFormatChanging
                ? "Mac screen format changed during remote input."
                : "Remote input was rate-limited."
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
        // Revoke both final-send gates before cancelling actor work. A send already inside the
        // gates linearizes before this call; queued work cannot enter afterward.
        cancelFocusedWindowResize()
        revokeRemoteScrollSendAuthorization()
        revokeRemoteInputLifecycleSendAuthorization()
        remoteInputAuthorization?.revoke()
        remoteInputAuthorization = nil
        remoteInputGeneration = UUID()
        remoteInputDrainTask?.cancel()
        remoteInputDrainTask = nil
        discardActiveRemoteScroll(removingQueuedPackets: false)
        remoteInputQueue.removeAll(keepingCapacity: false)
        pendingRemoteInputs.removeAll(keepingCapacity: false)
        pendingRemoteInputOrder.removeAll(keepingCapacity: false)
        earlyRemoteInputFeedback.removeAll(keepingCapacity: false)
        retiredFocusedWindowResizeRequests.removeAll(keepingCapacity: false)
        retiredFocusedWindowResizeRequestKeyOrder.removeAll(keepingCapacity: false)
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

    func debugInstallRawMicrophoneMissingStatisticsUptimeClock(
        _ clock: @escaping @MainActor () -> TimeInterval
    ) {
        debugRawMicrophoneMissingStatisticsUptimeClock = clock
    }

    func debugInstallStalledIPhoneMicrophoneRecoveryObserver(
        _ observer: @escaping @MainActor () -> Void
    ) {
        debugStalledIPhoneMicrophoneRecoveryObserver = observer
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

    func debugWaitForIPhoneMicrophoneTaskForTests() async {
        await microphoneTask?.value
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
            WebRTCInputVideoSize?,
            WebRTCInputCapability,
            WebRTCInputAuthorization,
            WebRTCInputSendAuthorization?
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
        diagnostic: String,
        queuedAction: WebRTCInputAction? = nil,
        viewerVideoSize: WebRTCInputVideoSize? = nil
    ) -> WebRTCInputAuthorization {
        invalidateRemoteInputState()
        sessionGeneration = UUID()
        peer = newPeer
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: focusGeneration,
            supportsPrimaryDrag: true,
            supportsScroll: true
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
        activeScreenRequestID = focusGeneration
        remoteHideRequired = true
        #if DEBUG
        debugCurrentScreenPresentationLease = lease
        debugActiveScreenPresentationLease = lease
        #endif
        lastDiagnostic = diagnostic
        let action = queuedAction ?? .returnKey(focusGeneration: focusGeneration)
        let pointerIntentID: UInt64?
        if action.isOrdinaryPointerAction {
            latestPointerIntentID = 1
            pointerIntentID = 1
        } else {
            pointerIntentID = nil
        }
        remoteInputQueue = [
            QueuedRemoteInput(
                action: action,
                capability: capability,
                authorization: authorization,
                sessionGeneration: sessionGeneration,
                inputGeneration: remoteInputGeneration,
                pointerIntentID: pointerIntentID,
                viewerVideoSize: viewerVideoSize,
                scrollGestureID: nil,
                sendAuthorization: currentRemoteInputLifecycleSendAuthorization(),
                focusedWindowResizeInteractionID: nil,
                focusedWindowResizeOperation: nil
            )
        ]
        return authorization
    }

    func debugDrainRemoteInputQueueForRaceTests() async {
        await drainRemoteInputQueue(inputGeneration: remoteInputGeneration)
    }

    func debugDeliverRemoteInputFeedbackForRaceTests(_ feedback: WebRTCInputFeedback) {
        handleRemoteInputFeedback(feedback)
    }

    func debugSetRemoteKeyboardFocusForTests(_ generation: UInt64?) {
        focusedInputGeneration = generation
        focusedInputIsSecure = false
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
                pointerIntentID: nil,
                viewerVideoSize: nil,
                scrollGestureID: nil,
                sendAuthorization: currentRemoteInputLifecycleSendAuthorization(),
                focusedWindowResizeInteractionID: nil,
                focusedWindowResizeOperation: nil
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
            earlyFeedbackCount: earlyRemoteInputFeedback.count,
            retiredRequestIDCount: retiredFocusedWindowResizeRequests.count,
            inputGeneration: remoteInputGeneration,
            activeScrollGestureID: activeRemoteScroll?.gestureID,
            focusedWindowResizeState: focusedWindowResizeState,
            focusedWindowResizeSendAuthorizationIsValid:
                focusedWindowResizeSendAuthorization?.isValid == true,
            latestPointerIntentID: latestPointerIntentID,
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
    func debugInstallScreenSessionForTests(
        peer newPeer: WebRTCPeer,
        generation: UUID = UUID(),
        visible: Bool = false,
        provenance: MediaSessionProvenance = .unauthenticated,
        bindAudioTransactionDevice: Bool = false
    ) -> Bool {
        debugFocusedWindowResizeTrackOwner = nil
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            clearRequestHistory: true
        )
        if bindAudioTransactionDevice {
            guard let binding =
                    newPeer.iOSAudioTransactionDeviceBinding,
                  audioLifecycle.bindIOSAudioTransactionDevice(
                    binding
                  ) else {
                return false
            }
        }
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
        if bindAudioTransactionDevice {
            startAudioTransactionEventLoop(
                peer: newPeer,
                generation: generation
            )
        }
        return true
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
        screenRequestID: UInt64 = 1,
        supportsScroll: Bool = false,
        supportsFocusedWindowResize: Bool = false
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
            supportsPrimaryDrag: true,
            supportsScroll: supportsScroll,
            supportsFocusedWindowResize: supportsFocusedWindowResize
        )
        let authorization = WebRTCInputAuthorization()
        debugFocusedWindowResizeTrackOwner = supportsFocusedWindowResize
            ? NSObject()
            : nil
        remoteInputCapability = capability
        remoteInputAuthorization = authorization
        focusedInputGeneration = screenRequestID
        focusedInputIsSecure = false
        currentScreenPresentationLease = lease
        activeScreenPresentationLease = lease
        remoteScreenOwnerLease = lease
        activeScreenRequestID = screenRequestID
        remoteHideRequired = true
        debugCurrentScreenPresentationLease = lease
        debugActiveScreenPresentationLease = lease
        return WorldwideScreenPresentationDebugFixture(
            lease: lease,
            authorization: authorization
        )
    }

    @discardableResult
    func debugReplaceRemoteInputCapabilityForTests(
        inputSessionID: UUID = UUID(),
        supportsFocusedWindowResize: Bool = true
    ) -> WebRTCInputAuthorization? {
        guard let current = remoteInputCapability else { return nil }
        let replacement = WebRTCInputCapability(
            inputSessionID: inputSessionID,
            screenRequestID: current.screenRequestID,
            protocolVersion: current.protocolVersion,
            maxMessageBytes: current.maxMessageBytes,
            supportsPrimaryDrag: current.supportsPrimaryDrag,
            supportsScroll: current.supportsScroll,
            supportsFocusedWindowResize: supportsFocusedWindowResize
        )
        let authorization = WebRTCInputAuthorization()
        installRemoteInputCapability(
            replacement,
            authorization: authorization
        )
        return authorization
    }

    func debugReplaceFocusedWindowResizeTrackForTests() {
        guard debugFocusedWindowResizeTrackOwner != nil else { return }
        remoteVideoTrackIdentityWillChange()
        debugFocusedWindowResizeTrackOwner = NSObject()
    }

    func debugScreenPeerIs(_ expectedPeer: WebRTCPeer) -> Bool {
        peer === expectedPeer
    }

    func debugInstallScreenMediaCancellationObserver(
        _ observer: @escaping @MainActor (WebRTCPeer, String) -> Void
    ) {
        debugScreenMediaCancellationObserver = observer
    }

    func debugInstallCompletedScreenMediaFenceForTests(
        lease: WorldwideScreenPresentationLease,
        minimumAcceptedRTPTimestamp: UInt32
    ) {
        guard screenPresentationIsVisible(lease) else { return }
        screenMediaViewerFence = WorldwideScreenMediaViewerFence(
            lease: lease,
            coverID: UUID(),
            forceCover: false,
            minimumAcceptedRTPTimestamp: minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: [],
            markerProof: nil,
            proofRequestRevision: 1,
            statusText: nil
        )
    }

    func debugInstallForcedScreenMediaFenceForTests(
        lease: WorldwideScreenPresentationLease,
        minimumAcceptedRTPTimestamp: UInt32
    ) {
        guard screenPresentationIsVisible(lease) else { return }
        screenMediaViewerFence = WorldwideScreenMediaViewerFence(
            lease: lease,
            coverID: UUID(),
            forceCover: true,
            minimumAcceptedRTPTimestamp: minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: [],
            markerProof: nil,
            proofRequestRevision: 1,
            statusText: "Screen paused for privacy"
        )
    }

    func debugInstallScreenLivenessUptimeClock(
        _ clock: @escaping @MainActor () -> UInt64
    ) {
        debugScreenLivenessUptimeClock = clock
    }

    func debugDeliverScreenMediaSuspensionForTests(
        _ notice: WebRTCScreenMediaSuspensionNotice,
        sourcePeer: WebRTCPeer
    ) {
        receiveScreenMediaSuspension(
            notice,
            sourcePeer: sourcePeer,
            sourceGeneration: sessionGeneration
        )
    }

    var debugScreenPresentationState: WorldwideScreenPresentationDebugState {
        WorldwideScreenPresentationDebugState(
            sessionGeneration: sessionGeneration,
            currentLease: currentScreenPresentationLease,
            activeLease: activeScreenPresentationLease,
            recoveringLease: recoveringScreenPresentationLease,
            activeScreenRequestID: activeScreenRequestID,
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
        clearRequestHistory: Bool = false,
        preservingRecoveryPresentation: Bool = false
    ) {
        let recoveryLease: WorldwideScreenPresentationLease? = if
            preservingRecoveryPresentation {
            recoveringScreenPresentationLease
                ?? {
                    guard isScreenVisible,
                          currentScreenPresentationLease
                            == activeScreenPresentationLease else {
                        return nil
                    }
                    return currentScreenPresentationLease
                }()
        } else {
            nil
        }
        let recoveryRevealFence: WorldwideScreenPresentationRecoveryRevealFence? = if
            let recoveryLease,
            let screenMediaViewerFence,
            screenMediaViewerFence.lease == recoveryLease,
            screenMediaViewerFence.forceCover {
            WorldwideScreenPresentationRecoveryRevealFence(screenMediaViewerFence)
        } else {
            nil
        }
        screenPresentationRecoveryTask?.cancel()
        screenPresentationRecoveryTask = nil
        screenPresentationRecoveryAttemptID = nil
        recoveringScreenPresentationLease = nil
        screenPresentationRevealAfterRecoveryFence = nil
        retireScreenMediaViewerAttempt(preservingFence: recoveryLease != nil)
        activeScreenRequestID = nil
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
        if let recoveryLease,
           recoveryLease.sessionGeneration == sessionGeneration {
            currentScreenPresentationLease = recoveryLease
            recoveringScreenPresentationLease = recoveryLease
            screenPresentationRevealAfterRecoveryFence = recoveryRevealFence
            #if DEBUG
            debugCurrentScreenPresentationLease = recoveryLease
            #endif
        }
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
        scheduleScreenPresentationRecoveryIfNeeded()
    }

    private func scheduleScreenPresentationRecoveryIfNeeded() {
        guard screenPresentationRecoveryTask == nil,
              !recoveryProofRequired,
              canViewScreen,
              let recoveryLease = recoveringScreenPresentationLease,
              screenPresentationIsCurrent(recoveryLease),
              let expectedPeer = peer else {
            return
        }

        let expectedGeneration = sessionGeneration
        let attemptID = UUID()
        screenPresentationRecoveryAttemptID = attemptID
        stateText = "Restoring screen"
        screenPresentationRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.screenPresentationRecoveryAttemptID == attemptID {
                    self.screenPresentationRecoveryTask = nil
                    self.screenPresentationRecoveryAttemptID = nil
                }
            }
            let maximumShowAttempts = 2
            for showAttempt in 1...maximumShowAttempts {
                let restored = await self.setScreenVisible(true, for: recoveryLease)
                guard self.screenPresentationRecoveryAttemptID == attemptID,
                      self.sessionGeneration == expectedGeneration,
                      self.peer === expectedPeer else {
                    return
                }
                if restored {
                    if self.recoveringScreenPresentationLease == recoveryLease {
                        self.recoveringScreenPresentationLease = nil
                    }
                    return
                }

                guard self.canViewScreen,
                      self.screenPresentationIsCurrent(recoveryLease),
                      self.recoveringScreenPresentationLease == recoveryLease else {
                    return
                }
                if self.screenPresentationNeedsRemoteHide(recoveryLease) {
                    self.stateText = "Securing screen recovery"
                    let hidden = await self.setScreenVisible(false, for: recoveryLease)
                    guard self.screenPresentationRecoveryAttemptID == attemptID,
                          self.sessionGeneration == expectedGeneration,
                          self.peer === expectedPeer else {
                        return
                    }
                    guard hidden else {
                        if self.hasActiveSession {
                            self.failSession(
                                "The Mac may still be sharing its screen after recovery, so the session was closed for privacy.",
                                generation: expectedGeneration
                            )
                        }
                        return
                    }
                }

                guard showAttempt < maximumShowAttempts else {
                    self.lastError =
                        "The Mac could not resume screen capture automatically."
                    self.stateText = "Connected"
                    self.retireScreenPresentationLease(recoveryLease)
                    return
                }
                self.stateText = "Restoring screen"
            }
        }
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
        if screenMediaViewerAttempt?.phase == .resumed {
            // A completed resume may still carry an RTP freshness floor. Keep that non-covering
            // fence with the retained drawable so transport recovery cannot reinstall black or
            // admit packets older than the last proven presentation.
            retireScreenMediaViewerAttempt(preservingFence: true)
        } else {
            cancelScreenMediaViewerSuspension(
                reason: "The secure media transport changed during screen resume.",
                notifyPeer: true
            )
        }
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
        resetScreenPresentationState(
            rotateQueueGeneration: true,
            preservingRecoveryPresentation: true
        )
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

        // Ownership is transferring from any older VM disable task to the peer's exact
        // retirement context. Invalidate the old task before publishing the transport binding so
        // a late return cannot clear or drain the token selected below.
        microphoneNativeTeardownID = nil
        microphoneTransportSuspensionBinding = nil

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
                return bindIPhoneMicrophoneTransportSuspensionToken(
                    executingToken,
                    retirementContext: retirementContext,
                    expectedPeerIdentity: expectedPeerIdentity,
                    expectedSessionGeneration: expectedSessionGeneration
                )
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
                    return bindIPhoneMicrophoneTransportSuspensionToken(
                        selectedToken,
                        retirementContext: retirementContext,
                        expectedPeerIdentity: expectedPeerIdentity,
                        expectedSessionGeneration:
                            expectedSessionGeneration
                    )

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
                return bindIPhoneMicrophoneTransportSuspensionToken(
                    candidate,
                    retirementContext: retirementContext,
                    expectedPeerIdentity: expectedPeerIdentity,
                    expectedSessionGeneration: expectedSessionGeneration
                )
            }
        }
    }

    private func bindIPhoneMicrophoneTransportSuspensionToken(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken,
        retirementContext: WebRTCIOSMicrophoneRetirementContext,
        expectedPeerIdentity: ObjectIdentifier,
        expectedSessionGeneration: UUID
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        guard expectedSessionGeneration == sessionGeneration,
              token.ownerEpoch == expectedSessionGeneration,
              retirementContext.selectedToken === token else {
            return nil
        }
        microphoneOutputOnlyToken = token
        microphoneTransportSuspensionBinding =
            MicrophoneTransportSuspensionBinding(
                sessionGeneration: expectedSessionGeneration,
                peerIdentity: expectedPeerIdentity,
                transportAuthorizationGeneration:
                    transportAuthorizationGeneration,
                microphoneOperationGeneration:
                    microphoneOperationGeneration,
                retirementID: retirementContext.retirementID,
                tokenID: token.tokenID,
                operationID: token.operationID
            )
        return token
    }

    private func completeIPhoneMicrophoneTransportSuspension(
        retirementContext: WebRTCIOSMicrophoneRetirementContext,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken,
        succeeded: Bool,
        expectedPeerIdentity: ObjectIdentifier,
        expectedSessionGeneration: UUID
    ) {
        guard let binding = microphoneTransportSuspensionBinding,
              binding.sessionGeneration == expectedSessionGeneration,
              binding.peerIdentity == expectedPeerIdentity,
              binding.retirementID == retirementContext.retirementID,
              binding.tokenID == outputOnlyToken.tokenID,
              binding.operationID == outputOnlyToken.operationID,
              microphoneOutputOnlyToken === outputOnlyToken else {
            return
        }

        microphoneTransportSuspensionBinding = nil
        recordNativeAudioTransactionTag(
            outputOnlyToken.stagedTransactionTagGeneration,
            context: outputOnlyToken.transaction
        )
        let bindingIsFresh =
            expectedSessionGeneration == sessionGeneration
            && peer.map(ObjectIdentifier.init)
                == expectedPeerIdentity
            && outputOnlyToken.ownerEpoch
                == expectedSessionGeneration
            && retirementContext.selectedToken
                === outputOnlyToken
            && binding.transportAuthorizationGeneration
                == transportAuthorizationGeneration
            && binding.microphoneOperationGeneration
                == microphoneOperationGeneration
        let completionWasAccepted = bindingIsFresh
            && succeeded
            && outputOnlyToken.state == .succeeded
            && audioLifecycle
                .completeValidatedTransportOutputOnlyTransition(
                    outputOnlyToken
                )
        if completionWasAccepted {
            microphoneOutputOnlyToken = nil
            return
        }

        let abandoned = audioLifecycle
            .abandonCurrentOutputOnlyTransitionRequiringReconnect(
                outputOnlyToken
            )
        if abandoned {
            microphoneOutputOnlyToken = nil
        }
        audioLifecycle.cancelPendingMicrophoneInputResume()
        microphoneAdmissionFailedSessionGeneration =
            expectedSessionGeneration
        microphoneStateText = "Unavailable"
        microphoneError =
            "The iPhone microphone could not finish its transport reset. Reconnect this session to restore it."
    }

    #if DEBUG
    func debugInstallIPhoneMicrophoneTransportSuspensionHandlersForTests(
        peer expectedPeer: WebRTCPeer
    ) async {
        guard peer === expectedPeer else { return }
        let expectedPeerIdentity = ObjectIdentifier(expectedPeer)
        let expectedSessionGeneration = sessionGeneration
        await expectedPeer
            .installIPhoneMicrophoneTransportSuspensionHandlers(
                preparation: { [weak self] retirementContext in
                    guard let self else { return nil }
                    return prepareIPhoneMicrophoneForTransportSuspension(
                        retirementContext: retirementContext,
                        expectedPeerIdentity: expectedPeerIdentity,
                        expectedSessionGeneration:
                            expectedSessionGeneration
                    )
                },
                completion: {
                    [weak self] retirementContext,
                    outputOnlyToken,
                    succeeded in
                    guard let self else { return }
                    completeIPhoneMicrophoneTransportSuspension(
                        retirementContext: retirementContext,
                        outputOnlyToken: outputOnlyToken,
                        succeeded: succeeded,
                        expectedPeerIdentity: expectedPeerIdentity,
                        expectedSessionGeneration:
                            expectedSessionGeneration
                    )
                }
            )
    }

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
        if recoveringScreenPresentationLease == lease {
            // Backgrounding is an explicit privacy boundary, not a recoverable transport gap.
            // Retire the retained drawable and cancel any automatic Show before the app can
            // become active again. If a Show already reached the transport, queue the matching
            // fail-closed Hide first so capture cannot outlive the local presentation.
            if screenPresentationNeedsRemoteHide(lease) {
                _ = beginPassiveScreenTeardown(for: lease)
            }
            retireScreenPresentationLease(lease)
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
    let earlyFeedbackCount: Int
    let retiredRequestIDCount: Int
    let inputGeneration: UUID
    let activeScrollGestureID: UUID?
    let focusedWindowResizeState: FocusedWindowResizeState
    let focusedWindowResizeSendAuthorizationIsValid: Bool
    let latestPointerIntentID: UInt64
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
    let viewerVideoSize: WebRTCInputVideoSize?
    let scrollGestureID: UUID?
    let sendAuthorization: WebRTCInputSendAuthorization?
    let focusedWindowResizeInteractionID: UUID?
    let focusedWindowResizeOperation: FocusedWindowResizePendingOperation?
}

private struct ActiveRemoteScroll {
    let gestureID: UUID
    let anchor: WebRTCNormalizedPoint
    let containerSize: CGSize
    let viewerVideoSize: CGSize
    let protocolVideoSize: WebRTCInputVideoSize
    let capability: WebRTCInputCapability
    let authorization: WebRTCInputAuthorization
    let sessionGeneration: UUID
    let inputGeneration: UUID
    let pointerIntentID: UInt64
    let sendAuthorization: WebRTCInputSendAuthorization
    var accumulator: RemoteScrollDeltaAccumulator
    var canFlushImmediately: Bool
    var isEnding: Bool
}

private extension WebRTCInputAction {
    var isFocusedWindowResizeAction: Bool {
        switch self {
        case .requestFocusedWindowResizeTarget,
             .selectWindowForResize,
             .commitFocusedWindowResize:
            true
        case .tap, .primaryDrag, .scroll,
             .insertText, .backspace, .returnKey:
            false
        }
    }

    var isOrdinaryPointerAction: Bool {
        switch self {
        case .tap, .primaryDrag, .scroll:
            true
        case .requestFocusedWindowResizeTarget,
             .selectWindowForResize,
             .commitFocusedWindowResize,
             .insertText,
             .backspace,
             .returnKey:
            false
        }
    }

    var requiresRemoteFocus: Bool {
        switch self {
        case .tap, .primaryDrag, .scroll,
             .requestFocusedWindowResizeTarget,
             .selectWindowForResize,
             .commitFocusedWindowResize:
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
    let sendAuthorization: WebRTCInputSendAuthorization?
    let requestScope: RemoteInputRequestScope
}

/// Request IDs are allocated by a peer and can restart at one after replacement. Carry the full
/// non-sensitive ownership scope beside every pending/retired correlation so an old completion
/// cannot claim a replacement peer's numerically identical request.
private struct RemoteInputRequestScope: Hashable {
    let sessionGeneration: UUID
    let peerIdentity: ObjectIdentifier
    let protocolVersion: Int
    let inputSessionID: UUID
    let screenRequestID: UInt64
    let maxMessageBytes: Int
    let supportsPrimaryDrag: Bool
    let supportsScroll: Bool
    let supportsFocusedWindowResize: Bool

    init(
        sessionGeneration: UUID,
        peer: WebRTCPeer,
        capability: WebRTCInputCapability
    ) {
        self.sessionGeneration = sessionGeneration
        peerIdentity = ObjectIdentifier(peer)
        protocolVersion = capability.protocolVersion
        inputSessionID = capability.inputSessionID
        screenRequestID = capability.screenRequestID
        maxMessageBytes = capability.maxMessageBytes
        supportsPrimaryDrag = capability.supportsPrimaryDrag
        supportsScroll = capability.supportsScroll
        supportsFocusedWindowResize = capability.supportsFocusedWindowResize
    }
}

private struct RetiredFocusedWindowResizeRequestKey: Hashable {
    let requestID: UInt64
    let requestScope: RemoteInputRequestScope
}

private struct RetiredFocusedWindowResizeRequest {
    let operation: FocusedWindowResizePendingOperation
    var didHandleFeedback = false
}

enum PendingRemoteInputKind: Equatable {
    case pointer
    case keyboard(focusGeneration: UInt64)
    case focusedWindowResize(
        interactionID: UUID,
        operation: FocusedWindowResizePendingOperation
    )

    init(
        _ action: WebRTCInputAction,
        focusedWindowResizeInteractionID: UUID? = nil,
        focusedWindowResizeOperation: FocusedWindowResizePendingOperation? = nil
    ) {
        switch action {
        case .tap, .primaryDrag, .scroll:
            self = .pointer
        case .requestFocusedWindowResizeTarget,
             .selectWindowForResize,
             .commitFocusedWindowResize:
            precondition(
                focusedWindowResizeInteractionID != nil
                    && focusedWindowResizeOperation?.matches(action) == true,
                "Resize actions require exact interaction metadata."
            )
            self = .focusedWindowResize(
                interactionID: focusedWindowResizeInteractionID!,
                operation: focusedWindowResizeOperation!
            )
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
