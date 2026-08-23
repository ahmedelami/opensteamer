import AVFoundation
import Foundation
import WebRTCTransport

struct AudioSessionCategoryChange: Equatable, Sendable {
    let category: String
    let mode: String
    let categoryOptionsRawValue: UInt
    let operationID: UUID?
    let operationIDIsAmbiguous: Bool
    /// Identity of the retired same-target operation whose tombstone made this notification
    /// ambiguous. A nil value means ambiguity was not causally bound to one predecessor.
    let ambiguousPredecessorOperationID: UUID?
    /// Identity of the retired same-target tombstone that blocked matching the current operation.
    /// Unlike `ambiguousPredecessorOperationID`, this does not claim that the notification came
    /// from that retired operation; it only explains why exact current-operation inference was
    /// intentionally withheld.
    let blockingTombstoneOperationID: UUID?

    init(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt = 0,
        operationID: UUID? = nil,
        operationIDIsAmbiguous: Bool = false,
        ambiguousPredecessorOperationID: UUID? = nil,
        blockingTombstoneOperationID: UUID? = nil
    ) {
        self.category = category
        self.mode = mode
        self.categoryOptionsRawValue = categoryOptionsRawValue
        self.operationID = operationID
        self.operationIDIsAmbiguous = operationIDIsAmbiguous
        self.ambiguousPredecessorOperationID =
            ambiguousPredecessorOperationID
        self.blockingTombstoneOperationID =
            blockingTombstoneOperationID
    }
}

/// Abstracts the process-wide WebRTC audio device for deterministic lifecycle tests.
@MainActor
protocol WorldwideAudioPlaybackManaging: AnyObject {
    var requiresRuntimePlayoutProof: Bool { get }

    func activate() throws
    func recover() throws
    func prepareForHostedCallInterruption()
    func prepareManualAudioDisabled()
    func activateArmedHostedCallPlayout()
    func deactivate()
}

/// Now Playing and bounded transition-task operations required by worldwide playback.
@MainActor
protocol BackgroundPlaybackCoordinating: AnyObject {
    func beginTransitionTask()
    func endTransitionTask()
    func publishLiveStream(serverName: String?, isPlaying: Bool)
    func clear()
}

/// AVAudioSession event source consumed by the worldwide audio policy.
@MainActor
protocol AudioSessionEventMonitoring: AnyObject {
    var onInterruptionBegan:
        ((AudioSessionInterruptionBeganReason) -> Void)? { get set }
    var onInterruptionEnded: ((Bool) -> Void)? { get set }
    var onRouteChanged: ((String) -> Void)? { get set }
    var onCategoryChanged: ((AudioSessionCategoryChange) -> Void)? { get set }
    var onEngineConfigurationChanged: (() -> Void)? { get set }
    var onMediaServicesLost: (() -> Void)? { get set }
    var onMediaServicesReset: (() -> Void)? { get set }

    func startObserving()
    func stopObserving()
    func updateRouteConfigurationChangePolicyEpoch(_ epoch: UInt64)
    func armCategoryChangeOperation(
        _ operationID: UUID,
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt
    )
    func cancelCategoryChangeOperation(_ operationID: UUID)
}

/// Per-track audio gate. It is intentionally separate from WebRTC's process-wide native gate.
@MainActor
protocol WorldwideRemoteAudioControlling: AnyObject {
    func setEnabled(_ enabled: Bool)
}

extension WebRTCAudioPlaybackSession: WorldwideAudioPlaybackManaging {
    var requiresRuntimePlayoutProof: Bool { true }
}
extension BackgroundPlaybackCoordinator: BackgroundPlaybackCoordinating {}
extension AudioSessionManager: AudioSessionEventMonitoring {}
extension WebRTCRemoteAudioTrack: WorldwideRemoteAudioControlling {}

/// UI-facing projection of the worldwide audio policy's independently tracked readiness gates.
struct WorldwideAudioLifecycleSnapshot: Equatable {
    let stateText: String
    let isRemoteAudioAvailable: Bool
    let isPlaying: Bool
    let requiresExplicitResume: Bool
    let errorText: String?
    let diagnosticText: String?
}

/// Unforgeable ownership for one call-end output-only recovery boundary. A replacement call or
/// lifecycle reset retires the exact UUID, so delayed native diagnostics cannot reopen input.
struct WorldwidePostCallMicrophoneRecoveryMilestone: Equatable, Sendable {
    fileprivate let generation: UUID
}

/// Microphone-specific interpretation of CallKit. Downlink keeps its existing raw call policy;
/// only a fresh, peer-bound Mac-hosted proof can convert one exact connected call from blocked to
/// eligible for the iPhone microphone.
enum WorldwideMicrophoneCallDisposition: Equatable, Sendable {
    case inactive
    case blocked
    case macHosted
}

/// One bounded request to re-prove a category transition whose sole AVAudioSession notification
/// was blocked by a retired same-target tombstone. The notification never completes the current
/// operation: this identity is carried through the native diagnostics attempt and is accepted only
/// while the exact operation, topology generation, and target policy remain current.
struct WorldwideAudioCategoryProofClaim: Equatable, Sendable {
    let claimID: UUID
    let operationID: UUID
    let operationEpoch: UInt64
    let microphoneTopologyGeneration: UInt64
    let category: String
    let mode: String
    let categoryOptionsRawValue: UInt
}

/// Owns only the iPhone playback side of a worldwide session. Screen privacy remains
/// independent: backgrounding can hide the Mac display while this controller keeps genuine
/// WebRTC audio playout active under iOS's Background Audio mode.
@MainActor
final class WorldwideAudioLifecycleController {
    var onSnapshotChanged: ((WorldwideAudioLifecycleSnapshot) -> Void)?
    /// The custom WebRTC audio device owns AVAudioSession/RemoteIO. App lifecycle and route
    /// policy call this only after reopening WebRTC's manual audio gate so the active peer can
    /// authorize a device rebuild on its ADM thread.
    var onPlaybackRecoveryRequested: (() -> Void)?
    /// Expected playback/playAndRecord topology changes require a fresh
    /// RemoteIO output proof but must not revoke the current microphone.
    var onPlayoutProofRefreshRequested: (() -> Void)?
    /// A same-target tombstone may withhold notification ownership from the current operation. This
    /// callback carries the exact current claim through the existing bounded native proof window;
    /// a proof without this claim cannot resolve that ambiguity.
    var onAmbiguousCategoryPlayoutProofRefreshRequested:
        ((WorldwideAudioCategoryProofClaim) -> Void)?
    /// CallKit is a synchronous microphone-ownership boundary only. A bare call
    /// transition does not close incoming playout gates.
    var onCallActivityChanged: ((Bool) -> Void)?
    /// Synchronous, fail-closed microphone disposition. Every new CallKit epoch publishes blocked
    /// before a later post-edge Mac heartbeat may publish macHosted.
    var onMicrophoneCallDispositionChanged:
        ((WorldwideMicrophoneCallDisposition) -> Void)?
    /// A privacy-minimal nonce that the current Mac peer must echo only after a fresh native
    /// FaceTime process scan. Nil retires any outstanding challenge.
    var onMacHostedCallChallengeChanged:
        ((WebRTCMacHostedCallChallenge?) -> Void)?
    /// Call inactivity is published before recovery for privacy ordering. Microphone policy may
    /// reopen only after the exact call-end native output-only milestone is proven.
    var onPostCallRecoveryCompleted: (() -> Void)?
    /// Interruptions can precede their matching CallKit transition. This independent callback
    /// retires proof ownership before interruption fencing, without incorrectly classifying every
    /// interruption as a phone call. An exact default interruption may preserve only the
    /// initialized manual WebRTC device while the native shim keeps RemoteIO and input fenced.
    var onAudioProofInvalidated: ((_ requiresFreshRecovery: Bool) -> Void)?
    /// A connected-call request carries persistent native ownership for one explicit startup or
    /// interruption origin. The proof layer must return readiness against this exact authorization.
    var onHostedCallPlayoutRecoveryRequested:
        ((WebRTCIOSHostedCallPlayoutAuthorization) -> Void)?
    /// Interruption-origin native recovery must not activate AVAudioSession until the system
    /// has delivered interruption-ended with a resume hint.
    var onHostedCallPlayoutRecoveryResumed:
        ((WebRTCIOSHostedCallPlayoutAuthorization) -> Void)?

    private let playback: any WorldwideAudioPlaybackManaging
    private let backgroundPlayback: any BackgroundPlaybackCoordinating
    private let events: any AudioSessionEventMonitoring
    private let callActivity: any WorldwideCallActivityObserving
    private var isPrepared = false
    private var playbackIsReady = false
    private var runtimePlayoutIsReady = false
    private var hasRemoteAudio = false
    private var transportIsHealthy = false
    private var isInterrupted = false
    /// Native microphone ownership ends when AVAudioSession delivers interruption-ended, even if
    /// the downlink policy intentionally keeps its broader hosted-call epoch open.
    private var microphoneInterruptionIsActive = false
    private var callActivitySnapshot =
        WorldwideCallActivitySnapshot.inactive
    private var macHostedCallEvidence: WebRTCMacHostedCallEvidence?
    private var macHostedCallChallenge: WebRTCMacHostedCallChallenge?
    /// Random privacy boundary for one exact non-ended CallKit membership set. It is stable while
    /// that same call moves from ringing to connected and across transport/interruption challenge
    /// rotations; no CXCall UUID is ever copied into this value or sent to the Mac.
    private var macHostedCallEpochNonce: UUID?
    private var nextMacHostedCallChallengeSequence: UInt64 = 1
    private var highestMacHostedCallEvidenceSequence: UInt64 = 0
    private var macHostedCallEvidenceSequenceFloor: UInt64 = 0
    /// Exact preflight-armed evidence that acknowledged a prospective next-call challenge.
    /// It never admits input; CallKit must still synchronously prove one connected call.
    private var armedMacHostedCallPreflightChallenge:
        WebRTCMacHostedCallChallenge?
    private var macHostedCallPreflightRetryTask: Task<Void, Never>?
    private static let macHostedCallPreflightRetryDelay:
        Duration = .seconds(2)
    #if DEBUG
    private var debugMacHostedCallPreflightRetryWaiter:
        (() async -> Void)?
    #endif
    private var callEpochHasSeenInterruption = false
    private var publishedMicrophoneCallDisposition:
        WorldwideMicrophoneCallDisposition = .inactive
    private var currentInterruptionEpoch: UUID?
    private var currentStartupConnectedCallScope: UUID?
    private var currentInterruptionReason:
        AudioSessionInterruptionBeganReason?
    private var hostedCallPolicy: HostedCallPolicy?
    private var hostedCallPolicyWasIssuedForCurrentInterruption = false
    private var hostedCallPolicyIsClosedForCurrentInterruption = false
    private var hostedInterruptionEndedAwaitingCallEnd = false
    private var waitsForConnectedCallToEndBeforeRecovery = false
    private var pendingPostCallMicrophoneRecoveryMilestone:
        WorldwidePostCallMicrophoneRecoveryMilestone?
    private var requiresExplicitResume = false
    private var mediaServicesAreLost = false
    private var playbackErrorText: String?
    private var playbackDiagnosticText: String?
    private var serverName = "Mac mini"
    private var remoteAudioControl: (any WorldwideRemoteAudioControlling)?
    private var microphoneTopologyGeneration: UInt64 = 0
    private var microphoneTopologyIsEnabled = false
    private var expectedAudioCategoryTransition:
        ExpectedAudioCategoryTransition?
    private var completedAudioCategoryTransition:
        ExpectedAudioCategoryTransition?
    private struct PendingAmbiguousCategoryProof {
        let claim: WorldwideAudioCategoryProofClaim
        let transition: ExpectedAudioCategoryTransition
    }
    private var pendingAmbiguousCategoryProof:
        PendingAmbiguousCategoryProof?
    private var audioOperationEpoch: UInt64 = 0
    /// Monotonic lifecycle-policy fence captured by native reason-8 notification ingress.
    private var routeConfigurationChangePolicyEpoch: UInt64 = 0

    private static let normalCategoryOptionsRawValue: UInt = 0
    private static let microphoneCategoryOptionsRawValue =
        AVAudioSession.CategoryOptions.defaultToSpeaker
            .union(.allowBluetoothA2DP)
            .rawValue
    private static let hostedCallCategoryOptionsRawValue =
        AVAudioSession.CategoryOptions.mixWithOthers.rawValue

    private static func ordinaryCategoryOptionsRawValue(
        microphoneIsEnabled: Bool
    ) -> UInt {
        microphoneIsEnabled
            ? microphoneCategoryOptionsRawValue
            : normalCategoryOptionsRawValue
    }

    private enum ExpectedAudioCategoryTransitionPurpose: Equatable {
        case topology
        case outputOnlyMicrophone
        case recovery
        case callPrivacyRollback
        case hostedCall
    }

    private struct ExpectedAudioCategoryTransition {
        let operationEpoch: UInt64
        let generation: UInt64
        let operationID: UUID
        let category: String
        let mode: String
        let categoryOptionsRawValue: UInt
        let purpose: ExpectedAudioCategoryTransitionPurpose
        let outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken?
        let hostedCallPolicyID: UUID?
        let admissiblePredecessorOperationID: UUID?
    }

    private enum HostedCallScope: Equatable {
        case startupConnectedCall(UUID)
        case interruption(UUID)

        var id: UUID {
            switch self {
            case .startupConnectedCall(let id), .interruption(let id):
                return id
            }
        }

        var origin: WebRTCIOSHostedCallPlayoutOrigin {
            switch self {
            case .startupConnectedCall:
                return .startupConnectedCall
            case .interruption:
                return .interruption
            }
        }
    }

    private struct HostedCallPolicy {
        let scope: HostedCallScope
        let authorization:
            WebRTCIOSHostedCallPlayoutAuthorization
        var runtimeGateIsAdmitted: Bool
    }

    init(
        playback: any WorldwideAudioPlaybackManaging,
        backgroundPlayback: any BackgroundPlaybackCoordinating,
        events: any AudioSessionEventMonitoring,
        callActivity: any WorldwideCallActivityObserving =
            WorldwideCallActivityObserver()
    ) {
        self.playback = playback
        self.backgroundPlayback = backgroundPlayback
        self.events = events
        self.callActivity = callActivity

        events.onInterruptionBegan = { [weak self] reason in
            self?.interruptionBegan(reason: reason)
        }
        events.onInterruptionEnded = { [weak self] shouldResume in
            self?.interruptionEnded(shouldResume: shouldResume)
        }
        events.onRouteChanged = { [weak self] message in
            self?.routeChanged(message)
        }
        events.onCategoryChanged = { [weak self] change in
            self?.categoryChanged(change)
        }
        events.onEngineConfigurationChanged = { [weak self] in
            self?.audioSystemConfigurationChanged(
                context: "Audio engine recovery failed"
            )
        }
        events.onMediaServicesLost = { [weak self] in
            self?.mediaServicesWereLost()
        }
        events.onMediaServicesReset = { [weak self] in
            self?.mediaServicesWereReset()
        }
        callActivity.onSnapshotChanged = { [weak self] snapshot in
            self?.callActivityChanged(snapshot)
        }
    }

    convenience init() {
        self.init(
            playback: WebRTCAudioPlaybackSession(),
            backgroundPlayback: BackgroundPlaybackCoordinator(),
            events: AudioSessionManager(),
            callActivity: WorldwideCallActivityObserver()
        )
    }

    var snapshot: WorldwideAudioLifecycleSnapshot {
        WorldwideAudioLifecycleSnapshot(
            stateText: stateText,
            isRemoteAudioAvailable: hasRemoteAudio,
            isPlaying: isPlaying,
            requiresExplicitResume: requiresExplicitResume,
            errorText: playbackErrorText,
            diagnosticText: playbackDiagnosticText
        )
    }

    var postCallMicrophoneRecoveryMilestone:
        WorldwidePostCallMicrophoneRecoveryMilestone? {
        pendingPostCallMicrophoneRecoveryMilestone
    }

    // MARK: - Session and application lifecycle

    func prepare(serverName: String) {
        guard !isPrepared else {
            updateServerName(serverName)
            return
        }

        self.serverName = serverName
        isPrepared = true
        playbackIsReady = false
        runtimePlayoutIsReady = !playback.requiresRuntimePlayoutProof
        hasRemoteAudio = false
        transportIsHealthy = false
        isInterrupted = false
        microphoneInterruptionIsActive = false
        callActivitySnapshot = .inactive
        macHostedCallEvidence = nil
        macHostedCallChallenge = nil
        macHostedCallEpochNonce = nil
        nextMacHostedCallChallengeSequence = 1
        highestMacHostedCallEvidenceSequence = 0
        macHostedCallEvidenceSequenceFloor = 0
        armedMacHostedCallPreflightChallenge = nil
        cancelMacHostedCallPreflightRetry()
        callEpochHasSeenInterruption = false
        publishedMicrophoneCallDisposition = .inactive
        currentInterruptionEpoch = nil
        currentStartupConnectedCallScope = nil
        currentInterruptionReason = nil
        hostedCallPolicy = nil
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
        pendingPostCallMicrophoneRecoveryMilestone = nil
        requiresExplicitResume = false
        mediaServicesAreLost = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        completedAudioCategoryTransition = nil
        expectedAudioCategoryTransition = nil

        // CallKit is sampled before any ordinary activation. Publishing the privacy boundary first
        // makes a launch into an already-running call close microphone ownership synchronously.
        callActivity.startObserving()
        events.startObserving()
        callActivitySnapshot = callActivity.liveSnapshot
        if callActivitySnapshot.hasNonEndedCall {
            macHostedCallEpochNonce = UUID()
            macHostedCallEvidenceSequenceFloor =
                highestMacHostedCallEvidenceSequence
            callEpochHasSeenInterruption =
                callEpochHasSeenInterruption
                    || microphoneInterruptionIsActive
            let challenge =
                replaceMacHostedCallChallengeForCurrentEpoch()
            publishMicrophoneCallDispositionIfChanged()
            onMacHostedCallChallengeChanged?(challenge)
        } else {
            let challenge = reserveFreshMacHostedCallPreflight()
            onMacHostedCallChallengeChanged?(challenge)
        }
        if isCallActive {
            onCallActivityChanged?(true)
        }

        if callActivitySnapshot.hasConnectedNonEndedCall {
            _ = advanceMicrophoneTopologyGeneration()
            microphoneTopologyIsEnabled = false
            runtimePlayoutIsReady = false
            playback.prepareManualAudioDisabled()
            onAudioProofInvalidated?(true)
            authorizeStartupConnectedCallPolicy()
            publishSnapshot()
            return
        }

        // Ringing-only startup keeps the microphone privacy boundary closed but may use the
        // ordinary best-effort playback/default policy.
        beginMicrophoneTopologyTransition(isEnabled: false)
        activateInitialPlayback()
        publishSnapshot()
    }

    private func activateInitialPlayback() {
        let activationTransition = expectedAudioCategoryTransition
        do {
            try playback.activate()
            guard let activationTransition,
                  consumeNativeOperationCommitIfCurrent(
                    activationTransition
                  ) else {
                failClosedAfterStaleNativeOperation()
                return
            }
            playbackIsReady = true
        } catch {
            guard let activationTransition,
                  consumeNativeOperationCommitIfCurrent(
                    activationTransition
                  ) else {
                failClosedAfterStaleNativeOperation()
                return
            }
            cancelExpectedAudioCategoryTransition()
            playback.deactivate()
            recordPlaybackFailure(
                context: "Initial background audio preparation failed",
                error: error
            )
        }
    }

    func updateServerName(_ serverName: String) {
        let trimmed = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.serverName = trimmed
        publishSnapshot()
    }

    func remoteAudioBecameAvailable(_ track: any WorldwideRemoteAudioControlling) {
        guard isPrepared else { return }
        if let previous = remoteAudioControl, previous !== track {
            previous.setEnabled(false)
        }
        remoteAudioControl = track
        hasRemoteAudio = true
        publishSnapshot()
        if isPlaying {
            // Once real playout is running, it—not a finite background task—provides the
            // continuous background execution eligibility.
            backgroundPlayback.endTransitionTask()
        }
    }

    /// Installs or revokes current-peer evidence after the view model has already checked peer,
    /// session, sequence, and lease ownership. Stale/regressing evidence is ignored locally too.
    func macHostedCallEvidenceChanged(
        _ evidence: WebRTCMacHostedCallEvidence?
    ) {
        guard isPrepared else { return }
        if evidence != nil {
            // Evidence admission is itself a microphone-opening boundary. Re-read CallKit before
            // consulting the cached disposition/challenge so a queued same-count call replacement
            // cannot admit proof issued for the retired call membership.
            synchronizeLiveCallStateIfNeeded()
            guard isPrepared else { return }
        }
        let previousDisposition = microphoneCallDisposition
        var replacementChallenge: WebRTCMacHostedCallChallenge?
        var didReplaceChallenge = false
        if let evidence {
            guard let challenge = macHostedCallChallenge,
                  evidence.isValid,
                  evidence.challengeSequence == challenge.sequence,
                  evidence.challengeNonce == challenge.nonce,
                  evidence.callEpochNonce == challenge.callEpochNonce,
                  evidence.sequence > highestMacHostedCallEvidenceSequence else {
                return
            }
            highestMacHostedCallEvidenceSequence = evidence.sequence
            if !callActivitySnapshot.hasNonEndedCall {
                if evidence.state == .preflightArmed {
                    macHostedCallEvidence = evidence
                    armedMacHostedCallPreflightChallenge = challenge
                    cancelMacHostedCallPreflightRetry()
                    publishMicrophoneCallDispositionIfChanged()
                    publishSnapshot()
                    return
                }

                // An active transition before live CallKit or an inactive poison/revocation must
                // not become a future call's proof. Retire the prospective epoch immediately; a
                // fresh known-empty preflight acknowledgement is required.
                replacementChallenge = reserveFreshMacHostedCallPreflight()
                didReplaceChallenge = true
                scheduleMacHostedCallPreflightRetryIfNeeded()
            } else {
                macHostedCallEvidence = evidence
            }
        } else {
            replacementChallenge = callActivitySnapshot.hasNonEndedCall
                ? replaceMacHostedCallChallengeForCurrentEpoch()
                : reserveFreshMacHostedCallPreflight()
            didReplaceChallenge = true
            scheduleMacHostedCallPreflightRetryIfNeeded()
        }

        let currentDisposition = microphoneCallDisposition

        if previousDisposition == .blocked,
           currentDisposition == .macHosted {
            // A Mac-hosted call uses the ordinary playback/play-and-record policy. Retire any
            // startup connected-call policy that was installed before transport evidence existed.
            revokeHostedCallPolicy()
            if !microphoneInterruptionIsActive {
                isInterrupted = false
                currentInterruptionEpoch = nil
                currentInterruptionReason = nil
                hostedCallPolicyWasIssuedForCurrentInterruption = false
                hostedCallPolicyIsClosedForCurrentInterruption = false
                hostedInterruptionEndedAwaitingCallEnd = false
            }
            waitsForConnectedCallToEndBeforeRecovery = false
            recoverPlayback(
                context: "Audio recovery for Mac-hosted FaceTime failed"
            )
            publishMicrophoneCallDispositionIfChanged()
        } else if previousDisposition == .macHosted,
                  currentDisposition == .blocked,
                  microphoneTopologyIsEnabled {
            publishMicrophoneCallDispositionIfChanged()
            retireMicrophoneTopologyForCallPrivacyBoundary()
        } else {
            publishMicrophoneCallDispositionIfChanged()
        }
        if didReplaceChallenge {
            onMacHostedCallChallengeChanged?(replacementChallenge)
        }
        publishSnapshot()
    }

    func transportBecameHealthy() {
        guard isPrepared else { return }
        guard !transportIsHealthy else {
            publishSnapshot()
            return
        }
        let previousMicrophoneDisposition =
            microphoneCallDisposition
        transportIsHealthy = true
        if callActivitySnapshot.hasNonEndedCall {
            onMacHostedCallChallengeChanged?(macHostedCallChallenge)
        } else {
            let challenge = macHostedCallChallenge
                ?? reserveFreshMacHostedCallPreflight()
            onMacHostedCallChallengeChanged?(challenge)
            scheduleMacHostedCallPreflightRetryIfNeeded()
        }
        if previousMicrophoneDisposition == .blocked,
           microphoneCallDisposition == .macHosted {
            revokeHostedCallPolicy()
            waitsForConnectedCallToEndBeforeRecovery = false
            recoverPlayback(
                context: "Audio recovery for Mac-hosted FaceTime failed"
            )
            publishMicrophoneCallDispositionIfChanged()
            return
        }
        publishMicrophoneCallDispositionIfChanged()
        if let policy = hostedCallPolicy,
           policy.scope.origin == .startupConnectedCall,
           hostedCallIntersectionHolds(policy) {
            publishSnapshot()
            return
        }
        recoverPlayback(context: "Audio transport recovery failed")
    }

    func transportBecameUncertain() {
        guard isPrepared else { return }
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        let wasTransportHealthy = transportIsHealthy
        revokeHostedCallPolicy()
        transportIsHealthy = false
        cancelMacHostedCallPreflightRetry()
        let challenge: WebRTCMacHostedCallChallenge?
        if callActivitySnapshot.hasNonEndedCall {
            challenge = replaceMacHostedCallChallengeForCurrentEpoch()
        } else {
            clearMacHostedCallChallenge()
            macHostedCallEpochNonce = nil
            armedMacHostedCallPreflightChallenge = nil
            challenge = nil
        }
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(challenge)

        if failedStartupPolicy {
            fenceFailedStartupConnectedCallPolicyUntilCallEnd(true)
            closePlaybackGatesAndInvalidateProof()
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            publishSnapshot()
            return
        }

        guard wasTransportHealthy else {
            publishSnapshot()
            return
        }
        cancelExpectedAudioCategoryTransition()
        publishSnapshot()
    }

    func appBecameActive() {
        guard isPrepared else { return }
        backgroundPlayback.endTransitionTask()
        recoverPlayback(context: "Audio foreground recovery failed")
    }

    func appBecameInactive() {
        guard isPrepared else { return }
        backgroundPlayback.beginTransitionTask()
        publishSnapshot()
    }

    func appEnteredBackground() {
        guard isPrepared else { return }
        backgroundPlayback.beginTransitionTask()
        recoverPlayback(context: "Background audio recovery failed")
    }

    func stop() {
        guard isPrepared else { return }

        let hadActiveCall = isCallActive
        revokeHostedCallPolicy()
        retireExpectedAudioCategoryTransitionForBoundary()
        remoteAudioControl?.setEnabled(false)
        remoteAudioControl = nil
        callActivity.stopObserving()
        events.stopObserving()
        playback.deactivate()
        backgroundPlayback.clear()
        isPrepared = false
        playbackIsReady = false
        runtimePlayoutIsReady = false
        hasRemoteAudio = false
        transportIsHealthy = false
        isInterrupted = false
        microphoneInterruptionIsActive = false
        callActivitySnapshot = .inactive
        macHostedCallEvidence = nil
        macHostedCallChallenge = nil
        macHostedCallEpochNonce = nil
        nextMacHostedCallChallengeSequence = 1
        highestMacHostedCallEvidenceSequence = 0
        macHostedCallEvidenceSequenceFloor = 0
        armedMacHostedCallPreflightChallenge = nil
        cancelMacHostedCallPreflightRetry()
        callEpochHasSeenInterruption = false
        publishedMicrophoneCallDisposition = .inactive
        currentInterruptionEpoch = nil
        currentStartupConnectedCallScope = nil
        currentInterruptionReason = nil
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
        pendingPostCallMicrophoneRecoveryMilestone = nil
        requiresExplicitResume = false
        mediaServicesAreLost = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        if hadActiveCall {
            onCallActivityChanged?(false)
        }
        onMacHostedCallChallengeChanged?(nil)
        publishSnapshot()
    }

    /// Explicit user recovery for interruptions or route removals where iOS declined automatic
    /// resume. Merely receiving more network packets must never clear this gate.
    func resumePlayback() {
        guard isPrepared,
              !mediaServicesAreLost,
              !hostedCallPolicyIsClosedForCurrentInterruption
        else {
            return
        }
        synchronizeLiveCallStateIfNeeded()
        guard !waitsForConnectedCallToEndBeforeRecovery else {
            publishSnapshot()
            return
        }
        requiresExplicitResume = false
        recoverPlayback(context: "Audio resume failed")
    }

    /// One guarded automatic rebuild for an already-proven native path whose realtime counters
    /// stopped. This never clears an explicit-resume privacy boundary and never substitutes for
    /// the user's route choice after a private output disappears.
    @discardableResult
    func requestAutomaticRuntimeAudioRecovery() -> Bool {
        guard isPrepared,
              hasRemoteAudio,
              transportIsHealthy,
              hostedCallPolicy == nil,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return false
        }

        closePlaybackGatesAndInvalidateProof()
        guard retireExpectedAudioCategoryTransitionForBoundary() else {
            publishSnapshot()
            return false
        }
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
        return recoverPlayback(
            context: "Automatic iPhone audio liveness recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    @discardableResult
    func beginMicrophoneTopologyTransition(isEnabled: Bool) -> UInt64 {
        guard isPrepared else { return 0 }
        revokeHostedCallPolicy()
        let predecessorOperationID =
            currentAudioCategoryTransitionOperationID
        guard cancelExpectedAudioCategoryTransition() else { return 0 }
        let generation = advanceMicrophoneTopologyGeneration()
        microphoneTopologyIsEnabled = isEnabled
        _ = installExpectedAudioCategoryTransition(
            operationID: UUID(),
            category: isEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.ordinaryCategoryOptionsRawValue(
                    microphoneIsEnabled: isEnabled
                ),
            purpose: .topology,
            outputOnlyToken: nil,
            admissiblePredecessorOperationID:
                predecessorOperationID
        )
        return generation
    }

    /// Arms the only lifecycle operation that may authorize a native nil microphone write.
    func beginIPhoneMicrophoneOutputOnlyTransition(
        ownerEpoch: UUID
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        guard isPrepared else {
            return nil
        }
        revokeHostedCallPolicy()
        let predecessorOperationID =
            currentAudioCategoryTransitionOperationID
        guard
              cancelExpectedAudioCategoryTransition() else {
            return nil
        }

        _ = advanceMicrophoneTopologyGeneration()
        microphoneTopologyIsEnabled = false

        let target = WebRTCIOSOutputOnlyMicrophoneTarget(
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue
        )
        let token = WebRTCIOSOutputOnlyMicrophoneToken(
            ownerEpoch: ownerEpoch,
            lifecycleGeneration: microphoneTopologyGeneration,
            target: target
        )
        _ = installExpectedAudioCategoryTransition(
            operationID: token.operationID,
            category: target.category,
            mode: target.mode,
            categoryOptionsRawValue:
                Self.normalCategoryOptionsRawValue,
            purpose: .outputOnlyMicrophone,
            outputOnlyToken: token,
            admissiblePredecessorOperationID:
                predecessorOperationID
        )
        return token
    }

    /// Reuses a public disable that already entered its exact native claim.
    func reuseIPhoneMicrophoneOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken,
        ownerEpoch: UUID
    ) -> Bool {
        let playbackCategory =
            AVAudioSession.Category.playback.rawValue
        let defaultMode = AVAudioSession.Mode.default.rawValue
        guard isPrepared,
              token.ownerEpoch == ownerEpoch,
              token.lifecycleGeneration
                == microphoneTopologyGeneration,
              token.target.category == playbackCategory,
              token.target.mode == defaultMode else {
            return false
        }

        if let expectedAudioCategoryTransition {
            return expectedAudioCategoryTransition.generation
                    == token.lifecycleGeneration
                && expectedAudioCategoryTransition.operationID
                    == token.operationID
                && expectedAudioCategoryTransition.category
                    == token.target.category
                && expectedAudioCategoryTransition.mode
                    == token.target.mode
                && expectedAudioCategoryTransition
                    .categoryOptionsRawValue
                    == Self.normalCategoryOptionsRawValue
                && expectedAudioCategoryTransition.purpose
                    == .outputOnlyMicrophone
                && expectedAudioCategoryTransition.outputOnlyToken.map {
                    $0 === token
                } == true
        }

        switch token.state {
        case .executing:
            microphoneTopologyIsEnabled = false
            _ = installExpectedAudioCategoryTransition(
                operationID: token.operationID,
                category: token.target.category,
                mode: token.target.mode,
                categoryOptionsRawValue:
                    Self.normalCategoryOptionsRawValue,
                purpose: .outputOnlyMicrophone,
                outputOnlyToken: token
            )
            return true
        case .succeeded, .failed:
            // An absent marker after native completion means its synchronous callback or terminal
            // cleanup already consumed the one-shot ownership.
            return true
        case .armed, .revoked:
            return false
        }
    }

    /// Revocation is effective only before the token enters its native claim.
    func revokeIPhoneMicrophoneOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) {
        token.revoke()
        guard token.state == .revoked else { return }
        _ = cancelExpectedAudioCategoryTransition(
            operationID: token.operationID,
            purpose: .outputOnlyMicrophone,
            terminalCleanup: true
        )
    }

    /// Retries a call-end recovery that was deferred while this exact output-only native write
    /// was still executing. Completion during an active call remains observational; call end will
    /// retire a terminal token itself before arming the fresh UUID-bound recovery operation.
    func iPhoneMicrophoneOutputOnlyTransitionDidComplete(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) {
        guard isPrepared,
              token.state == .succeeded || token.state == .failed else {
            return
        }
        synchronizeLiveCallStateIfNeeded()
        guard ownsIPhoneMicrophoneOutputOnlyTransition(token) else {
            return
        }
        if microphoneCallDisposition == .blocked {
            guard cancelExpectedAudioCategoryTransition(
                operationID: token.operationID,
                purpose: .outputOnlyMicrophone,
                terminalCleanup: true
            ) else { return }
            if isInterrupted {
                authorizeHostedCallPolicyIfEligible(
                    admissiblePredecessorOperationID:
                        token.operationID
                )
            } else {
                _ = installExpectedAudioCategoryTransition(
                    operationID: UUID(),
                    category:
                        AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.default.rawValue,
                    categoryOptionsRawValue:
                        Self.normalCategoryOptionsRawValue,
                    purpose: .callPrivacyRollback,
                    outputOnlyToken: nil,
                    admissiblePredecessorOperationID:
                        token.operationID
                )
            }
            publishSnapshot()
            return
        }
        guard pendingPostCallMicrophoneRecoveryMilestone != nil else {
            _ = cancelExpectedAudioCategoryTransition(
                operationID: token.operationID,
                purpose: .outputOnlyMicrophone,
                terminalCleanup: true
            )
            authorizeHostedCallPolicyIfEligible(
                admissiblePredecessorOperationID:
                    token.operationID
            )
            publishSnapshot()
            return
        }
        recoverPlayback(
            context:
                "Audio recovery after microphone teardown and call end failed"
        )
    }

    @discardableResult
    private func armExpectedAudioCategoryTransition(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        purpose: ExpectedAudioCategoryTransitionPurpose
    ) -> UUID? {
        let predecessorOperationID =
            currentAudioCategoryTransitionOperationID
        guard cancelExpectedAudioCategoryTransition() else {
            return nil
        }
        let operationID = UUID()
        return installExpectedAudioCategoryTransition(
            operationID: operationID,
            category: category,
            mode: mode,
            categoryOptionsRawValue: categoryOptionsRawValue,
            purpose: purpose,
            outputOnlyToken: nil,
            admissiblePredecessorOperationID:
                predecessorOperationID
        )
    }

    @discardableResult
    private func installExpectedAudioCategoryTransition(
        operationID: UUID,
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        purpose: ExpectedAudioCategoryTransitionPurpose,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken?,
        hostedCallPolicyID: UUID? = nil,
        admissiblePredecessorOperationID: UUID? = nil
    ) -> UUID {
        precondition(expectedAudioCategoryTransition == nil)
        pendingAmbiguousCategoryProof = nil
        completedAudioCategoryTransition = nil
        let operationEpoch = advanceAudioOperationEpoch()
        expectedAudioCategoryTransition = ExpectedAudioCategoryTransition(
            operationEpoch: operationEpoch,
            generation: microphoneTopologyGeneration,
            operationID: operationID,
            category: category,
            mode: mode,
            categoryOptionsRawValue: categoryOptionsRawValue,
            purpose: purpose,
            outputOnlyToken: outputOnlyToken,
            hostedCallPolicyID: hostedCallPolicyID,
            admissiblePredecessorOperationID:
                admissiblePredecessorOperationID
        )
        events.armCategoryChangeOperation(
            operationID,
            category: category,
            mode: mode,
            categoryOptionsRawValue: categoryOptionsRawValue
        )
        return operationID
    }

    @discardableResult
    private func cancelExpectedAudioCategoryTransition(
        operationID: UUID? = nil,
        purpose: ExpectedAudioCategoryTransitionPurpose? = nil,
        terminalCleanup: Bool = false
    ) -> Bool {
        if let expectedAudioCategoryTransition {
            guard audioCategoryTransition(
                expectedAudioCategoryTransition,
                matchesOperationID: operationID,
                purpose: purpose
            ) else {
                return false
            }

            guard retireOutputOnlyTokenIfAdmissible(
                expectedAudioCategoryTransition.outputOnlyToken,
                terminalCleanup: terminalCleanup
            ) else { return false }

            events.cancelCategoryChangeOperation(
                expectedAudioCategoryTransition.operationID
            )
            if pendingAmbiguousCategoryProof?.transition.operationID
                == expectedAudioCategoryTransition.operationID {
                pendingAmbiguousCategoryProof = nil
            }
            self.expectedAudioCategoryTransition = nil
            completedAudioCategoryTransition = nil
            _ = advanceAudioOperationEpoch()
            return true
        }

        guard let completedAudioCategoryTransition else {
            return true
        }
        guard audioCategoryTransition(
            completedAudioCategoryTransition,
            matchesOperationID: operationID,
            purpose: purpose
        ) else {
            return false
        }
        guard retireOutputOnlyTokenIfAdmissible(
            completedAudioCategoryTransition.outputOnlyToken,
            terminalCleanup: terminalCleanup
        ) else { return false }
        if pendingAmbiguousCategoryProof?.transition.operationID
            == completedAudioCategoryTransition.operationID {
            pendingAmbiguousCategoryProof = nil
        }
        self.completedAudioCategoryTransition = nil
        _ = advanceAudioOperationEpoch()
        return true
    }

    /// An executing token is still inside the native one-shot closure. Neither a synchronous
    /// category callback nor a reentrant lifecycle boundary may relinquish its ownership until
    /// `performOnce` has published a terminal result.
    private func retireOutputOnlyTokenIfAdmissible(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken?,
        terminalCleanup: Bool
    ) -> Bool {
        guard let token else { return true }
        switch token.state {
        case .armed:
            token.revoke()
            return true
        case .executing:
            return false
        case .succeeded, .failed:
            return terminalCleanup
        case .revoked:
            return true
        }
    }

    private func audioCategoryTransition(
        _ transition: ExpectedAudioCategoryTransition,
        matchesOperationID operationID: UUID?,
        purpose: ExpectedAudioCategoryTransitionPurpose?
    ) -> Bool {
        if let operationID,
           transition.operationID != operationID {
            return false
        }
        if let purpose,
           transition.purpose != purpose {
            return false
        }
        return true
    }

    private func ownsIPhoneMicrophoneOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        let transition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        return transition?.purpose == .outputOnlyMicrophone
            && transition?.operationID == token.operationID
            && transition?.outputOnlyToken === token
    }

    private var currentAudioCategoryTransitionOperationID: UUID? {
        (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?.operationID
    }

    @discardableResult
    private func retireExpectedAudioCategoryTransitionForBoundary() -> Bool {
        cancelExpectedAudioCategoryTransition(
            terminalCleanup: true
        )
    }

    private func retireMicrophoneTopologyForCallPrivacyBoundary() {
        let predecessor = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        let markerWasRetired =
            retireExpectedAudioCategoryTransitionForBoundary()
        microphoneTopologyIsEnabled = false
        _ = advanceMicrophoneTopologyGeneration()
        guard markerWasRetired else { return }
        _ = installExpectedAudioCategoryTransition(
            operationID: UUID(),
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.normalCategoryOptionsRawValue,
            purpose: .callPrivacyRollback,
            outputOnlyToken: nil,
            admissiblePredecessorOperationID:
                predecessor?.operationID
        )
    }

    private func completeExpectedAudioCategoryTransition(
        _ transition: ExpectedAudioCategoryTransition
    ) {
        if pendingAmbiguousCategoryProof?.transition.operationID
            == transition.operationID {
            pendingAmbiguousCategoryProof = nil
        }
        expectedAudioCategoryTransition = nil
        completedAudioCategoryTransition = transition
        events.cancelCategoryChangeOperation(
            transition.operationID
        )
    }

    private func nativeOperationIsCurrent(
        _ operation: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard isPrepared,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost,
              operation.operationEpoch == audioOperationEpoch,
              operation.generation == microphoneTopologyGeneration
        else {
            return false
        }

        if let expectedAudioCategoryTransition,
           audioCategoryTransition(
            expectedAudioCategoryTransition,
            exactlyMatches: operation
           ) {
            return true
        }

        if let completedAudioCategoryTransition,
           audioCategoryTransition(
            completedAudioCategoryTransition,
            exactlyMatches: operation
           ) {
            return true
        }

        return false
    }

    private func consumeNativeOperationCommitIfCurrent(
        _ operation: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard nativeOperationIsCurrent(operation) else {
            return false
        }
        if let completedAudioCategoryTransition,
           audioCategoryTransition(
            completedAudioCategoryTransition,
            exactlyMatches: operation
           ) {
            self.completedAudioCategoryTransition = nil
        }
        return true
    }

    private func audioCategoryTransition(
        _ lhs: ExpectedAudioCategoryTransition,
        exactlyMatches rhs: ExpectedAudioCategoryTransition
    ) -> Bool {
        let outputOnlyTokensMatch: Bool
        switch (lhs.outputOnlyToken, rhs.outputOnlyToken) {
        case (nil, nil):
            outputOnlyTokensMatch = true
        case let (lhsToken?, rhsToken?):
            outputOnlyTokensMatch = lhsToken === rhsToken
        default:
            outputOnlyTokensMatch = false
        }

        return lhs.operationEpoch == rhs.operationEpoch
            && lhs.generation == rhs.generation
            && lhs.operationID == rhs.operationID
            && lhs.category == rhs.category
            && lhs.mode == rhs.mode
            && lhs.categoryOptionsRawValue
                == rhs.categoryOptionsRawValue
            && lhs.purpose == rhs.purpose
            && outputOnlyTokensMatch
            && lhs.hostedCallPolicyID == rhs.hostedCallPolicyID
            && lhs.admissiblePredecessorOperationID
                == rhs.admissiblePredecessorOperationID
    }

    @discardableResult
    private func advanceAudioOperationEpoch() -> UInt64 {
        audioOperationEpoch &+= 1
        if audioOperationEpoch == 0 {
            audioOperationEpoch = 1
        }
        advanceRouteConfigurationChangePolicyEpoch()
        return audioOperationEpoch
    }

    @discardableResult
    private func advanceMicrophoneTopologyGeneration() -> UInt64 {
        microphoneTopologyGeneration &+= 1
        if microphoneTopologyGeneration == 0 {
            microphoneTopologyGeneration = 1
        }
        advanceRouteConfigurationChangePolicyEpoch()
        return microphoneTopologyGeneration
    }

    private func advanceRouteConfigurationChangePolicyEpoch() {
        routeConfigurationChangePolicyEpoch &+= 1
        if routeConfigurationChangePolicyEpoch == 0 {
            routeConfigurationChangePolicyEpoch = 1
        }
        events.updateRouteConfigurationChangePolicyEpoch(
            routeConfigurationChangePolicyEpoch
        )
    }

    /// Accepts proof from the output-only RemoteIO render-input boundary. Signaling, a decoded
    /// track, and WebRTC's global audio gate are insufficient even for that boundary, and healthy
    /// callback PCM is not evidence of the later iOS mixer/route/DAC/speaker output.
    func updateRuntimePlayout(
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil,
        categoryProofClaim: WorldwideAudioCategoryProofClaim? = nil
    ) {
        guard isPrepared,
              !isInterrupted,
              hostedCallPolicy == nil,
              !requiresExplicitResume,
              !mediaServicesAreLost,
              playback.requiresRuntimePlayoutProof else { return }

        if let pendingAmbiguousCategoryProof {
            guard let categoryProofClaim,
                  ambiguousCategoryProofClaim(
                    categoryProofClaim,
                    stillOwns: pendingAmbiguousCategoryProof
                  ) else {
                // A stale or ordinary proof must never resolve a notification whose ownership was
                // withheld by a same-target tombstone. The current transition and both media gates
                // remain closed until its own bounded proof succeeds or reports terminal failure.
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                publishSnapshot()
                return
            }
        } else if categoryProofClaim != nil {
            // The claim's operation retired or was replaced while diagnostics were suspended.
            // Ignore the stale result without mutating the replacement operation.
            return
        }

        let ownsAmbiguousCategoryProof =
            pendingAmbiguousCategoryProof != nil
                && categoryProofClaim != nil
        runtimePlayoutIsReady = isReady
        if let failureMessage {
            playbackIsReady = false
            playbackErrorText = failureMessage
            playbackDiagnosticText = diagnostic
            if ownsAmbiguousCategoryProof {
                // An exact claimed proof is the only replacement for the withheld category
                // notification. Its terminal failure must close the native WebRTC device gate as
                // well as the decoded-track/readiness gates; a second OS notification is neither
                // required nor allowed to rescue this operation.
                closePlaybackGatesAndInvalidateProof()
            }
        } else if isReady {
            playbackIsReady = true
            playbackErrorText = nil
            playbackDiagnosticText = nil
        }
        if isReady || failureMessage != nil {
            cancelExpectedAudioCategoryTransition(
                terminalCleanup: true
            )
        }
        publishSnapshot()
        if isPlaying {
            backgroundPlayback.endTransitionTask()
        }
    }

    private func ambiguousCategoryProofClaim(
        _ claim: WorldwideAudioCategoryProofClaim,
        stillOwns pending: PendingAmbiguousCategoryProof
    ) -> Bool {
        let transition = pending.transition
        guard claim == pending.claim,
              claim.operationID == transition.operationID,
              claim.operationEpoch == transition.operationEpoch,
              claim.microphoneTopologyGeneration == transition.generation,
              claim.category == transition.category,
              claim.mode == transition.mode,
              claim.categoryOptionsRawValue
                == transition.categoryOptionsRawValue,
              let current = expectedAudioCategoryTransition,
              audioCategoryTransition(current, exactlyMatches: transition),
              nativeOperationIsCurrent(transition),
              expectedCategoryPolicyMatches(
                transition,
                change: AudioSessionCategoryChange(
                    category: claim.category,
                    mode: claim.mode,
                    categoryOptionsRawValue:
                        claim.categoryOptionsRawValue,
                    operationID: nil
                )
              ),
              outputOnlyTokenIsAdmissible(for: transition) else {
            return false
        }
        return true
    }

    /// Fails only the exact hosted-call policy and authorization owned by the current startup or
    /// interruption scope. Native rejection may already have invalidated the authorization, so
    /// object identity—not validity or recovery state—is the terminal failure fence.
    @MainActor
    func failHostedCallRuntimePlayout(
        policyID: UUID,
        authorization:
            WebRTCIOSHostedCallPlayoutAuthorization,
        failureMessage: String,
        diagnostic: String?
    ) {
        guard isPrepared else { return }
        synchronizeLiveCallStateIfNeeded()
        guard
            let policy = hostedCallPolicy,
            policy.authorization.policyID == policyID,
            policy.authorization === authorization
        else {
            return
        }

        let failedStartupPolicy =
            policy.scope.origin == .startupConnectedCall
        if policy.scope.origin == .interruption {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        retireExpectedAudioCategoryTransitionForBoundary()
        playbackErrorText = failureMessage
        playbackDiagnosticText = diagnostic
        closePlaybackGatesAndInvalidateProof()
        publishSnapshot()
    }

    /// Applies hosted-call runtime evidence only to the exact policy issued for its explicit
    /// startup or interruption scope. A pending native claim is not runtime readiness and cannot
    /// open the decoded-track gate.
    func updateHostedCallRuntimePlayout(
        policyID: UUID,
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil
    ) {
        guard isPrepared else { return }
        synchronizeLiveCallStateIfNeeded()
        guard
            var policy = hostedCallPolicy,
            policy.authorization.policyID == policyID,
            policy.authorization.isValid,
            !policy.authorization.isRecoveryPending,
            policy.authorization.origin == policy.scope.origin,
            hostedCallIntersectionHolds(policy),
            policy.scope.origin != .interruption
                || !hostedCallPolicyIsClosedForCurrentInterruption,
            !mediaServicesAreLost,
            !requiresExplicitResume,
            !waitsForConnectedCallToEndBeforeRecovery
        else {
            return
        }

        if let transition = expectedAudioCategoryTransition {
            guard transition.generation
                    == microphoneTopologyGeneration,
                  transition.operationID == policyID,
                  transition.purpose == .hostedCall,
                  transition.hostedCallPolicyID == policyID,
                  transition.category
                    == AVAudioSession.Category.playback.rawValue,
                  transition.mode
                    == AVAudioSession.Mode.default.rawValue,
                  transition.categoryOptionsRawValue
                    == Self.hostedCallCategoryOptionsRawValue
            else {
                return
            }
        }
        if let pendingAmbiguousCategoryProof {
            guard pendingAmbiguousCategoryProof.claim.operationID
                    == policyID,
                  let transition = expectedAudioCategoryTransition,
                  audioCategoryTransition(
                    transition,
                    exactlyMatches:
                        pendingAmbiguousCategoryProof.transition
                  ) else {
                return
            }
        }

        if let failureMessage {
            let failedStartupPolicy =
                policy.scope.origin == .startupConnectedCall
            revokeHostedCallPolicy()
            fenceFailedStartupConnectedCallPolicyUntilCallEnd(
                failedStartupPolicy
            )
            runtimePlayoutIsReady = false
            playbackIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackErrorText = failureMessage
            playbackDiagnosticText = diagnostic
            onAudioProofInvalidated?(true)
            playback.prepareManualAudioDisabled()
            publishSnapshot()
            return
        }

        guard cancelExpectedAudioCategoryTransition(
            operationID: policyID,
            purpose: .hostedCall,
            terminalCleanup: true
        ) else {
            return
        }
        policy.runtimeGateIsAdmitted = true
        hostedCallPolicy = policy
        playbackIsReady = true
        runtimePlayoutIsReady = isReady
        playbackErrorText = nil
        playbackDiagnosticText = nil
        publishSnapshot()
        if isPlaying {
            backgroundPlayback.endTransitionTask()
        }
    }

    func hostedCallScopeID(
        for authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) -> UUID? {
        guard isPrepared,
              let policy = hostedCallPolicy,
              policy.authorization === authorization,
              policy.authorization.policyID == authorization.policyID,
              policy.authorization.origin == policy.scope.origin else {
            return nil
        }
        return policy.scope.id
    }

    /// Opens only WebRTC's manual global gate after native startup ownership has been armed. This
    /// method performs no AVAudioSession configuration or activation; the first native StartPlayout
    /// must build directly under the already-installed startup-connected-call policy.
    @discardableResult
    func activateArmedStartupConnectedCallPlayout(
        scopeID: UUID,
        policyID: UUID,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        guard
            let policy = hostedCallPolicy,
            policy.scope == .startupConnectedCall(scopeID),
            currentStartupConnectedCallScope == scopeID,
            policy.authorization === authorization,
            policy.authorization.policyID == policyID,
            policy.authorization.origin == .startupConnectedCall,
            policy.authorization.isValid,
            !policy.authorization.isRecoveryPending,
            policy.authorization.systemAudioGeneration != 0,
            hostedCallIntersectionHolds(policy),
            transportIsHealthy,
            !mediaServicesAreLost,
            !requiresExplicitResume,
            !waitsForConnectedCallToEndBeforeRecovery,
            let transition = expectedAudioCategoryTransition,
            transition.generation == microphoneTopologyGeneration,
            transition.operationID == policyID,
            transition.purpose == .hostedCall,
            transition.hostedCallPolicyID == policyID,
            transition.category == AVAudioSession.Category.playback.rawValue,
            transition.mode == AVAudioSession.Mode.default.rawValue,
            transition.categoryOptionsRawValue
                == Self.hostedCallCategoryOptionsRawValue
        else {
            return false
        }

        playback.activateArmedHostedCallPlayout()

        guard
            let current = hostedCallPolicy,
            current.scope == policy.scope,
            current.authorization === authorization,
            current.authorization.isValid,
            !current.authorization.isRecoveryPending,
            current.authorization.systemAudioGeneration
                == authorization.systemAudioGeneration,
            hostedCallIntersectionHolds(current)
        else {
            playback.prepareManualAudioDisabled()
            return false
        }

        playbackIsReady = true
        runtimePlayoutIsReady = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        publishSnapshot()
        return true
    }

    // MARK: - System event handling

    private func callActivityChanged(
        _ snapshot: WorldwideCallActivitySnapshot
    ) {
        guard isPrepared, snapshot != callActivitySnapshot else { return }

        let previousSnapshot = callActivitySnapshot
        let previousMicrophoneDisposition =
            microphoneCallDisposition
        let callWasActive = isCallActive
        let callBecameActive = snapshot.hasNonEndedCall && !callWasActive
        let callMembershipChanged = snapshot.hasNonEndedCall
            && (
                !callWasActive
                    || snapshot.membershipRevision
                        != previousSnapshot.membershipRevision
                    || snapshot.nonEndedCallCount
                        != previousSnapshot.nonEndedCallCount
            )
        callActivitySnapshot = snapshot
        let activeCallEpochWasInvalidated = snapshot.hasNonEndedCall
            && (
                !callWasActive
                    || snapshot.revision != previousSnapshot.revision
                    || snapshot.membershipRevision
                        != previousSnapshot.membershipRevision
                    || snapshot.nonEndedCallCount
                        != previousSnapshot.nonEndedCallCount
                    || snapshot.connectedNonEndedCallCount
                        != previousSnapshot.connectedNonEndedCallCount
            )
        var challengeUpdateWasRequired = false
        var replacementChallenge: WebRTCMacHostedCallChallenge?
        if activeCallEpochWasInvalidated {
            // Any new/changed CallKit epoch closes input first. Only a later heartbeat with a
            // strictly higher sequence can prove that this exact epoch is hosted on the Mac.
            macHostedCallEvidenceSequenceFloor =
                highestMacHostedCallEvidenceSequence
            let preservesProspectiveEpoch = callBecameActive
                && macHostedCallChallenge?.isValid == true
                && macHostedCallEpochNonce
                    == macHostedCallChallenge?.callEpochNonce
                && armedMacHostedCallPreflightChallenge
                    == macHostedCallChallenge
                && !microphoneInterruptionIsActive
                && !callEpochHasSeenInterruption
            cancelMacHostedCallPreflightRetry()
            armedMacHostedCallPreflightChallenge = nil
            if callMembershipChanged && !preservesProspectiveEpoch {
                macHostedCallEpochNonce = UUID()
            }
            callEpochHasSeenInterruption =
                callEpochHasSeenInterruption
                    || microphoneInterruptionIsActive
            macHostedCallEvidence = nil
            if preservesProspectiveEpoch {
                // The exact challenge was already installed prospectively. Do not rotate after
                // CallKit's edge: the Mac may already be observing the duplex transition.
                replacementChallenge = macHostedCallChallenge
            } else {
                replacementChallenge =
                    replaceMacHostedCallChallengeForCurrentEpoch()
                challengeUpdateWasRequired = true
            }
        } else if !snapshot.hasNonEndedCall {
            callEpochHasSeenInterruption = false
            macHostedCallEvidenceSequenceFloor =
                highestMacHostedCallEvidenceSequence
            replacementChallenge = reserveFreshMacHostedCallPreflight()
            challengeUpdateWasRequired = true
            scheduleMacHostedCallPreflightRetryIfNeeded()
        }
        publishMicrophoneCallDispositionIfChanged()
        if challengeUpdateWasRequired {
            onMacHostedCallChallengeChanged?(replacementChallenge)
        }
        if snapshot.hasNonEndedCall {
            pendingPostCallMicrophoneRecoveryMilestone = nil
        } else if callWasActive {
            pendingPostCallMicrophoneRecoveryMilestone =
                WorldwidePostCallMicrophoneRecoveryMilestone(
                    generation: UUID()
                )
        }

        let microphoneBecameBlocked =
            previousMicrophoneDisposition != .blocked
                && microphoneCallDisposition == .blocked
        if callBecameActive {
            // Revoke the realtime input authorization synchronously before changing logical
            // topology or category ownership. Authorization revocation is the privacy boundary;
            // downlink remains open while the retired native enable settles.
            onCallActivityChanged?(true)
            guard isPrepared,
                  callActivitySnapshot == snapshot else {
                return
            }
            if microphoneTopologyIsEnabled {
                retireMicrophoneTopologyForCallPrivacyBoundary()
            }
        } else if microphoneBecameBlocked,
                  microphoneTopologyIsEnabled {
            retireMicrophoneTopologyForCallPrivacyBoundary()
        }
        let startupPolicyLost: Bool
        if let policy = hostedCallPolicy,
           !hostedCallIntersectionHolds(policy) {
            startupPolicyLost =
                policy.scope.origin == .startupConnectedCall
            revokeHostedCallPolicy()
        } else {
            startupPolicyLost = false
        }

        if !callBecameActive {
            // Call end is still published before any recovery can reopen input. Same-state CallKit
            // aggregate changes are harmlessly deduplicated by the view-model boundary.
            onCallActivityChanged?(snapshot.hasNonEndedCall)
            guard isPrepared,
                  callActivitySnapshot == snapshot else {
                return
            }
        }

        if hostedInterruptionEndedAwaitingCallEnd,
           !snapshot.hasConnectedNonEndedCall {
            hostedInterruptionEndedAwaitingCallEnd = false
            isInterrupted = false
            currentInterruptionEpoch = nil
            currentInterruptionReason = nil
            hostedCallPolicyWasIssuedForCurrentInterruption = false
            hostedCallPolicyIsClosedForCurrentInterruption = false
            waitsForConnectedCallToEndBeforeRecovery = false
            closePlaybackGatesAndInvalidateProof()
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            guard !requiresExplicitResume,
                  !mediaServicesAreLost else {
                publishSnapshot()
                return
            }
            recoverPlayback(
                context:
                    "Audio recovery after connected call ended failed",
                proofAlreadyInvalidated: true
            )
            return
        }

        if startupPolicyLost, !isInterrupted {
            waitsForConnectedCallToEndBeforeRecovery = false
            closePlaybackGatesAndInvalidateProof()
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            guard !requiresExplicitResume,
                  !mediaServicesAreLost else {
                publishSnapshot()
                return
            }
            recoverPlayback(
                context: "Audio recovery after connected-call startup ended failed",
                proofAlreadyInvalidated: true
            )
            return
        }

        if waitsForConnectedCallToEndBeforeRecovery,
           !isInterrupted,
           !snapshot.hasConnectedNonEndedCall {
            waitsForConnectedCallToEndBeforeRecovery = false
            if requiresExplicitResume {
                publishSnapshot()
            } else {
                recoverPlayback(
                    context: "Audio interruption recovery failed",
                    proofAlreadyInvalidated: true
                )
            }
            return
        }

        if callWasActive, !snapshot.hasNonEndedCall {
            // A bare CallKit transition does not close downlink, but its end must still rebuild
            // native output-only policy before the microphone authorization may be recreated.
            recoverPlayback(
                context: "Audio recovery after call ended failed"
            )
            return
        }

        authorizeHostedCallPolicyIfEligible()
        publishSnapshot()
    }

    private func interruptionBegan(
        reason: AudioSessionInterruptionBeganReason
    ) {
        guard isPrepared else { return }
        let predecessorOperationID =
            currentAudioCategoryTransitionOperationID
        revokeHostedCallPolicy()
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
        currentInterruptionEpoch = UUID()
        currentInterruptionReason = reason
        isInterrupted = true
        microphoneInterruptionIsActive = true
        cancelMacHostedCallPreflightRetry()
        if callActivitySnapshot.hasNonEndedCall {
            callEpochHasSeenInterruption = true
            clearMacHostedCallChallenge()
        } else {
            clearMacHostedCallChallenge()
            macHostedCallEpochNonce = nil
            armedMacHostedCallPreflightChallenge = nil
        }
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(nil)
        // Close decoded-track and runtime-proof gates before terminally clearing any executing or
        // completed output-only marker. Only an exact default interruption preserves the same
        // initialized manual WebRTC device so the native interruption fence can later consume an
        // exact hosted authorization. Every other reason closes the process-wide gate.
        closePlaybackGatesAndInvalidateProof(
            preservingInitializedWebRTCAudioDevice: reason == .default
        )
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
        synchronizeLiveCallStateIfNeeded()
        authorizeHostedCallPolicyIfEligible(
            admissiblePredecessorOperationID:
                predecessorOperationID
        )
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isPrepared else { return }
        let preservedInitializedWebRTCAudioDevice =
            currentInterruptionReason == .default
        synchronizeLiveCallStateIfNeeded()
        microphoneInterruptionIsActive = false
        callEpochHasSeenInterruption = false
        let replacementChallenge = callActivitySnapshot.hasNonEndedCall
            ? replaceMacHostedCallChallengeForCurrentEpoch()
            : reserveFreshMacHostedCallPreflight()
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(replacementChallenge)
        scheduleMacHostedCallPreflightRetryIfNeeded()

        if hostedInterruptionEndedAwaitingCallEnd {
            publishSnapshot()
            return
        }

        if shouldResume,
           preservedInitializedWebRTCAudioDevice,
           let policy = hostedCallPolicy,
           policy.scope.origin == .interruption,
           policy.authorization.isValid,
           policy.authorization.isRecoveryPending,
           hostedCallIntersectionHolds(policy),
           !hostedCallPolicyIsClosedForCurrentInterruption,
           !mediaServicesAreLost {
            // Keep the app-owned interruption epoch open until call end so no ordinary recovery
            // can race the exact hosted policy. Native interruption state is independent.
            hostedInterruptionEndedAwaitingCallEnd = true
            onHostedCallPlayoutRecoveryResumed?(
                policy.authorization
            )
            publishSnapshot()
            return
        }

        revokeHostedCallPolicy()
        hostedInterruptionEndedAwaitingCallEnd = false
        isInterrupted = false
        currentInterruptionEpoch = nil
        currentInterruptionReason = nil
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        onAudioProofInvalidated?(false)
        if preservedInitializedWebRTCAudioDevice {
            playback.prepareManualAudioDisabled()
        }
        if callActivitySnapshot.hasConnectedNonEndedCall {
            waitsForConnectedCallToEndBeforeRecovery = true
            if !shouldResume {
                requiresExplicitResume = true
            }
            publishSnapshot()
            return
        }

        waitsForConnectedCallToEndBeforeRecovery = false
        guard shouldResume else {
            requiresExplicitResume = true
            publishSnapshot()
            return
        }
        recoverPlayback(
            context: "Audio interruption recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    private func routeChanged(_ message: String) {
        guard isPrepared else { return }
        let challenge = replaceMacHostedCallChallengeForCurrentState()
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(challenge)
        scheduleMacHostedCallPreflightRetryIfNeeded()
        let requiresPrivateRouteResume =
            message == "Audio route changed: device unavailable"
                || message
                    == "Audio route changed: no suitable route"
        let failedStartupPolicy = ownsStartupConnectedCallPolicy

        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            // A non-category route event permanently closes hosted authorization for this
            // interruption epoch, including when CallKit has not yet delivered the connected call.
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        if requiresPrivateRouteResume {
            // Do not leak a loud stream to speakers when headphones disappear. The user can
            // explicitly resume after choosing the intended route.
            requiresExplicitResume = true
        }
        closePlaybackGatesAndInvalidateProof()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()

        guard !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            return
        }
        recoverPlayback(
            context: "Audio route recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    private func audioSystemConfigurationChanged(
        context: String
    ) {
        guard isPrepared else { return }
        let challenge = replaceMacHostedCallChallengeForCurrentState()
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(challenge)
        scheduleMacHostedCallPreflightRetryIfNeeded()
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        if isInterrupted || failedStartupPolicy {
            closePlaybackGatesAndInvalidateProof()
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            publishSnapshot()
            return
        }
        recoverPlayback(context: context)
    }

    private func mediaServicesWereLost() {
        guard isPrepared else { return }
        mediaServicesAreLost = true
        let challenge = replaceMacHostedCallChallengeForCurrentState()
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(challenge)
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        closePlaybackGatesAndInvalidateProof()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
    }

    private func mediaServicesWereReset() {
        guard isPrepared else { return }
        mediaServicesAreLost = false
        let challenge = replaceMacHostedCallChallengeForCurrentState()
        publishMicrophoneCallDispositionIfChanged()
        onMacHostedCallChallengeChanged?(challenge)
        scheduleMacHostedCallPreflightRetryIfNeeded()
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        // Reset is a fresh native boundary. Close first, retire any operation that was executing
        // when reset reentered, then begin only a newly stamped recovery operation.
        closePlaybackGatesAndInvalidateProof()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()

        guard !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery else {
            return
        }
        recoverPlayback(
            context: "Audio services recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    private func categoryChanged(_ change: AudioSessionCategoryChange) {
        guard isPrepared else { return }

        if let transition = expectedAudioCategoryTransition,
           absorbRetiredMicrophoneEnableCategoryChangeIfAdmissible(
               change,
               rollbackTransition: transition
           ) {
            return
        }

        guard let expectedAudioCategoryTransition,
              expectedAudioCategoryTransition.generation
                == microphoneTopologyGeneration,
              expectedAudioCategoryTransition.category == change.category,
              expectedAudioCategoryTransition.mode == change.mode,
              expectedAudioCategoryTransition.categoryOptionsRawValue
                == change.categoryOptionsRawValue else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }

        guard expectedCategoryPolicyMatches(
            expectedAudioCategoryTransition,
            change: change
        ), outputOnlyTokenIsAdmissible(
            for: expectedAudioCategoryTransition
        ) else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }

        if change.operationIDIsAmbiguous {
            handleAmbiguousExpectedCategoryChange(
                change,
                transition: expectedAudioCategoryTransition
            )
            return
        }

        guard change.operationID
                == expectedAudioCategoryTransition.operationID else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }

        if let pendingAmbiguousCategoryProof,
           audioCategoryTransition(
               pendingAmbiguousCategoryProof.transition,
               exactlyMatches: expectedAudioCategoryTransition
           ) {
            // The claimed native proof exclusively owns completion once a tombstone has withheld
            // notification ownership. A later inferred callback for the current operation is only
            // observational; it must not clear the claim or reopen the ordinary proof path.
            return
        }

        if expectedAudioCategoryTransition.purpose == .hostedCall {
            // AVAudioSession did not carry the policy ID. Even an inferred matching operation is
            // observational only; exact native diagnostics against the authorization remain the
            // readiness proof and perform the eventual transition retirement.
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            publishSnapshot()
            return
        }

        let purpose = expectedAudioCategoryTransition.purpose
        completeExpectedAudioCategoryTransition(
            expectedAudioCategoryTransition
        )
        playbackErrorText = nil
        playbackDiagnosticText = nil
        if purpose != .hostedCall,
           purpose != .callPrivacyRollback {
            runtimePlayoutIsReady =
                !playback.requiresRuntimePlayoutProof
        }
        if playback.requiresRuntimePlayoutProof {
            switch purpose {
            case .topology, .outputOnlyMicrophone:
                if !isInterrupted {
                    onPlayoutProofRefreshRequested?()
                }
            case .recovery:
                break
            case .callPrivacyRollback:
                break
            case .hostedCall:
                break
            }
        }
        publishSnapshot()
        if purpose != .hostedCall {
            authorizeHostedCallPolicyIfEligible(
                admissiblePredecessorOperationID:
                    expectedAudioCategoryTransition.operationID
            )
        }
    }

    private func expectedCategoryPolicyMatches(
        _ transition: ExpectedAudioCategoryTransition,
        change: AudioSessionCategoryChange
    ) -> Bool {
        switch transition.purpose {
        case .hostedCall:
            guard
                let policy = hostedCallPolicy,
                policy.authorization.isValid,
                policy.authorization.origin == policy.scope.origin,
                policy.scope.origin != .interruption
                    || !hostedCallPolicyIsClosedForCurrentInterruption,
                !mediaServicesAreLost,
                transition.hostedCallPolicyID
                    == policy.authorization.policyID,
                change.category
                    == AVAudioSession.Category.playback.rawValue,
                change.mode == AVAudioSession.Mode.default.rawValue,
                change.categoryOptionsRawValue
                    == Self.hostedCallCategoryOptionsRawValue,
                hostedCallIntersectionHolds(policy)
            else {
                return false
            }
            return true

        case .topology, .recovery:
            let currentCategory = microphoneTopologyIsEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue
            return transition.hostedCallPolicyID == nil
                && change.category == currentCategory
                && change.mode == AVAudioSession.Mode.default.rawValue
                && change.categoryOptionsRawValue
                    == Self.ordinaryCategoryOptionsRawValue(
                        microphoneIsEnabled:
                            microphoneTopologyIsEnabled
                    )

        case .outputOnlyMicrophone:
            return !microphoneTopologyIsEnabled
                && transition.hostedCallPolicyID == nil
                && change.category
                    == AVAudioSession.Category.playback.rawValue
                && change.mode == AVAudioSession.Mode.default.rawValue
                && change.categoryOptionsRawValue
                    == Self.normalCategoryOptionsRawValue

        case .callPrivacyRollback:
            return microphoneCallDisposition == .blocked
                && !microphoneTopologyIsEnabled
                && transition.hostedCallPolicyID == nil
                && transition.category
                    == AVAudioSession.Category.playback.rawValue
                && change.category
                    == AVAudioSession.Category.playback.rawValue
                && change.mode == AVAudioSession.Mode.default.rawValue
                && change.categoryOptionsRawValue
                    == Self.normalCategoryOptionsRawValue
        }
    }

    private func absorbRetiredMicrophoneEnableCategoryChangeIfAdmissible(
        _ change: AudioSessionCategoryChange,
        rollbackTransition: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard rollbackTransition.purpose == .callPrivacyRollback,
              microphoneCallDisposition == .blocked,
              !microphoneTopologyIsEnabled,
              let predecessorOperationID =
                rollbackTransition.admissiblePredecessorOperationID,
              change.category
                == AVAudioSession.Category.playAndRecord.rawValue,
              change.mode == AVAudioSession.Mode.default.rawValue,
              change.categoryOptionsRawValue
                == Self.microphoneCategoryOptionsRawValue,
              change.operationID == predecessorOperationID
                || (change.operationID == nil
                    && change.operationIDIsAmbiguous
                    && change.ambiguousPredecessorOperationID
                        == predecessorOperationID)
        else {
            return false
        }

        // The exact realtime authorization was already revoked before this fence was installed.
        // This is only the queued notification from that retired native enable; accepting it keeps
        // downlink live while call-end recovery later proves a real output-only installation.
        publishSnapshot()
        return true
    }

    private func outputOnlyTokenIsAdmissible(
        for transition: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard transition.purpose == .outputOnlyMicrophone else {
            return true
        }
        guard let token = transition.outputOnlyToken,
              token.lifecycleGeneration == transition.generation,
              token.operationID == transition.operationID,
              token.target.category == transition.category,
              token.target.mode == transition.mode,
              transition.categoryOptionsRawValue
                == Self.normalCategoryOptionsRawValue,
              token.state == .executing
                || token.state == .succeeded else {
            return false
        }
        return true
    }

    private func handleAmbiguousExpectedCategoryChange(
        _ change: AudioSessionCategoryChange,
        transition: ExpectedAudioCategoryTransition
    ) {
        guard let admissiblePredecessorOperationID =
                transition.admissiblePredecessorOperationID,
              change.ambiguousPredecessorOperationID
                    == admissiblePredecessorOperationID
                || change.blockingTombstoneOperationID
                    == admissiblePredecessorOperationID else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }
        switch transition.purpose {
        case .hostedCall:
            _ = installPendingAmbiguousCategoryProof(for: transition)
            runtimePlayoutIsReady = false
            // The policy remains pending, but neither native nor decoded-track readiness can open
            // until diagnostics prove the exact authorization.
            playbackIsReady = false
            remoteAudioControl?.setEnabled(false)
            publishSnapshot()

        case .topology, .outputOnlyMicrophone:
            runtimePlayoutIsReady = false
            guard playback.requiresRuntimePlayoutProof else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            guard !isInterrupted,
                  let request =
                    onAmbiguousCategoryPlayoutProofRefreshRequested else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            let claim = installPendingAmbiguousCategoryProof(
                for: transition
            )
            remoteAudioControl?.setEnabled(false)
            request(claim)
            publishSnapshot()

        case .recovery:
            runtimePlayoutIsReady = false
            guard playback.requiresRuntimePlayoutProof else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            guard !isInterrupted,
                  let request =
                    onAmbiguousCategoryPlayoutProofRefreshRequested else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            let claim = installPendingAmbiguousCategoryProof(
                for: transition
            )
            remoteAudioControl?.setEnabled(false)
            request(claim)
            publishSnapshot()

        case .callPrivacyRollback:
            // A tombstoned same-target rollback notification is observational only. Call end
            // replaces this fence with an exact native output-only recovery authorization.
            publishSnapshot()
        }
    }

    private func installPendingAmbiguousCategoryProof(
        for transition: ExpectedAudioCategoryTransition
    ) -> WorldwideAudioCategoryProofClaim {
        if let pending = pendingAmbiguousCategoryProof,
           audioCategoryTransition(
            pending.transition,
            exactlyMatches: transition
           ) {
            return pending.claim
        }
        let claim = WorldwideAudioCategoryProofClaim(
            claimID: UUID(),
            operationID: transition.operationID,
            operationEpoch: transition.operationEpoch,
            microphoneTopologyGeneration: transition.generation,
            category: transition.category,
            mode: transition.mode,
            categoryOptionsRawValue:
                transition.categoryOptionsRawValue
        )
        pendingAmbiguousCategoryProof = PendingAmbiguousCategoryProof(
            claim: claim,
            transition: transition
        )
        return claim
    }

    private func failClosedForUnexpectedCategoryChange(
        _ change: AudioSessionCategoryChange
    ) {
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        playbackErrorText =
            "The iPhone audio route changed outside opensteamer’s authorized microphone policy."
        playbackDiagnosticText =
            "Unexpected AVAudioSession category=\(change.category), mode=\(change.mode), options=\(change.categoryOptionsRawValue)."
        closePlaybackGatesAndInvalidateProof()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
    }

    @discardableResult
    private func recoverPlayback(
        context: String,
        proofAlreadyInvalidated: Bool = false
    ) -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        guard !isInterrupted,
              hostedCallPolicy == nil,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return false
        }

        if !proofAlreadyInvalidated {
            onAudioProofInvalidated?(false)
        }
        if pendingPostCallMicrophoneRecoveryMilestone != nil,
           let transition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition,
           transition.purpose == .outputOnlyMicrophone,
           let token = transition.outputOnlyToken,
           token.state == .succeeded || token.state == .failed {
            guard cancelExpectedAudioCategoryTransition(
                operationID: transition.operationID,
                purpose: .outputOnlyMicrophone,
                terminalCleanup: true
            ) else {
                publishSnapshot()
                return false
            }
        }
        guard let recoveryOperationID =
            armExpectedAudioCategoryTransition(
            category: microphoneTopologyIsEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.ordinaryCategoryOptionsRawValue(
                    microphoneIsEnabled:
                        microphoneTopologyIsEnabled
                ),
            purpose: .recovery
            ) else {
            publishSnapshot()
            return false
        }
        guard let recoveryTransition =
                expectedAudioCategoryTransition,
              recoveryTransition.operationID
                == recoveryOperationID else {
            failClosedAfterStaleNativeOperation()
            publishSnapshot()
            return false
        }
        do {
            try playback.recover()
            guard consumeNativeOperationCommitIfCurrent(
                recoveryTransition
            ) else {
                failClosedAfterStaleNativeOperation()
                publishSnapshot()
                return false
            }
            playbackIsReady = true
            runtimePlayoutIsReady = !playback.requiresRuntimePlayoutProof
            playbackErrorText = nil
            playbackDiagnosticText = nil
            if !playback.requiresRuntimePlayoutProof {
                cancelExpectedAudioCategoryTransition(
                    operationID: recoveryOperationID
                )
            }
            onPlaybackRecoveryRequested?()
            publishSnapshot()
            if isPlaying {
                backgroundPlayback.endTransitionTask()
            }
            return true
        } catch {
            guard consumeNativeOperationCommitIfCurrent(
                recoveryTransition
            ) else {
                failClosedAfterStaleNativeOperation()
                publishSnapshot()
                return false
            }
            cancelExpectedAudioCategoryTransition(
                operationID: recoveryOperationID
            )
            playbackIsReady = false
            recordPlaybackFailure(context: context, error: error)
            publishSnapshot()
            return false
        }
    }

    private func closePlaybackGatesAndInvalidateProof(
        preservingInitializedWebRTCAudioDevice: Bool = false
    ) {
        runtimePlayoutIsReady = false
        playbackIsReady = false
        remoteAudioControl?.setEnabled(false)
        onAudioProofInvalidated?(true)
        if preservingInitializedWebRTCAudioDevice {
            playback.prepareForHostedCallInterruption()
        } else {
            playback.prepareManualAudioDisabled()
        }
    }

    private func failClosedAfterStaleNativeOperation() {
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        if isInterrupted {
            hostedCallPolicyIsClosedForCurrentInterruption = true
        }
        closePlaybackGatesAndInvalidateProof()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
    }

    private func recordPlaybackFailure(context: String, error: Error) {
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        playbackErrorText = "Screen and control are still available. iOS interrupted or rejected the current audio route. Restore the intended route, then tap Retry Audio."
        playbackDiagnosticText = "\(context): \(error.localizedDescription)"
    }

    @discardableResult
    func completePostCallMicrophoneRecovery(
        _ milestone: WorldwidePostCallMicrophoneRecoveryMilestone
    ) -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        guard pendingPostCallMicrophoneRecoveryMilestone
                == milestone,
              !isCallActive,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost,
              hostedCallPolicy == nil,
              transportIsHealthy,
              playbackIsReady
        else {
            return false
        }
        pendingPostCallMicrophoneRecoveryMilestone = nil
        onPostCallRecoveryCompleted?()
        return true
    }

    private var ownsStartupConnectedCallPolicy: Bool {
        hostedCallPolicy?.scope.origin == .startupConnectedCall
    }

    private func fenceFailedStartupConnectedCallPolicyUntilCallEnd(
        _ failedStartupPolicy: Bool
    ) {
        guard failedStartupPolicy else { return }
        waitsForConnectedCallToEndBeforeRecovery =
            callActivitySnapshot.hasConnectedNonEndedCall
    }

    /// Re-reads CallKit synchronously at every microphone-opening boundary.
    func microphoneActivationIsAllowed() -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        return microphoneCallDisposition != .blocked
            && !microphoneInterruptionIsActive
            && !requiresExplicitResume
            && !mediaServicesAreLost
    }

    private func synchronizeLiveCallStateIfNeeded() {
        guard isPrepared else { return }
        let liveSnapshot = callActivity.liveSnapshot
        if liveSnapshot != callActivitySnapshot {
            callActivityChanged(liveSnapshot)
        }
    }

    // MARK: - Derived policy state

    private var isCallActive: Bool {
        callActivitySnapshot.hasNonEndedCall
    }

    private var microphoneCallDisposition:
        WorldwideMicrophoneCallDisposition {
        guard callActivitySnapshot.hasNonEndedCall else {
            return .inactive
        }
        guard callActivitySnapshot.nonEndedCallCount == 1,
              callActivitySnapshot.connectedNonEndedCallCount == 1,
              !microphoneInterruptionIsActive,
              !callEpochHasSeenInterruption,
              transportIsHealthy,
              !requiresExplicitResume,
              !mediaServicesAreLost,
              let challenge = macHostedCallChallenge,
              challenge.isValid,
              let evidence = macHostedCallEvidence,
              evidence.isValid,
              evidence.challengeSequence == challenge.sequence,
              evidence.challengeNonce == challenge.nonce,
              evidence.callEpochNonce == challenge.callEpochNonce,
              evidence.state == .active,
              evidence.sequence > macHostedCallEvidenceSequenceFloor else {
            return .blocked
        }
        return .macHosted
    }

    private func publishMicrophoneCallDispositionIfChanged() {
        let disposition = microphoneCallDisposition
        guard disposition != publishedMicrophoneCallDisposition else {
            return
        }
        publishedMicrophoneCallDisposition = disposition
        onMicrophoneCallDispositionChanged?(disposition)
    }

    /// Replaces the current nonce without publishing it. Callers first publish the fail-closed
    /// microphone disposition, then notify the view model so challenge transmission cannot race
    /// ahead of synchronous authorization revocation.
    private func replaceMacHostedCallChallengeForCurrentEpoch()
        -> WebRTCMacHostedCallChallenge? {
        macHostedCallEvidence = nil
        armedMacHostedCallPreflightChallenge = nil
        guard callActivitySnapshot.hasNonEndedCall,
              let callEpochNonce = macHostedCallEpochNonce,
              !microphoneInterruptionIsActive,
              !callEpochHasSeenInterruption,
              nextMacHostedCallChallengeSequence < UInt64.max else {
            macHostedCallChallenge = nil
            return nil
        }
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: nextMacHostedCallChallengeSequence,
            callEpochNonce: callEpochNonce
        )
        nextMacHostedCallChallengeSequence &+= 1
        macHostedCallChallenge = challenge
        return challenge
    }

    private func replaceMacHostedCallChallengeForCurrentState()
        -> WebRTCMacHostedCallChallenge? {
        callActivitySnapshot.hasNonEndedCall
            ? replaceMacHostedCallChallengeForCurrentEpoch()
            : reserveFreshMacHostedCallPreflight()
    }

    private func clearMacHostedCallChallenge() {
        macHostedCallEvidence = nil
        macHostedCallChallenge = nil
        armedMacHostedCallPreflightChallenge = nil
    }

    /// Reserves a fresh epoch for the next CallKit membership while the phone is connected and
    /// inactive. The Mac can therefore establish its strict known-empty baseline before FaceTime
    /// becomes duplex. This carries no microphone authority until live CallKit later proves one
    /// connected call and active evidence arrives for this exact challenge.
    private func reserveFreshMacHostedCallPreflight()
        -> WebRTCMacHostedCallChallenge? {
        cancelMacHostedCallPreflightRetry()
        macHostedCallEvidence = nil
        armedMacHostedCallPreflightChallenge = nil
        guard isPrepared,
              !callActivitySnapshot.hasNonEndedCall,
              !microphoneInterruptionIsActive,
              !isInterrupted,
              !mediaServicesAreLost,
              nextMacHostedCallChallengeSequence < UInt64.max else {
            macHostedCallChallenge = nil
            macHostedCallEpochNonce = nil
            return nil
        }
        let epoch = UUID()
        let challenge = WebRTCMacHostedCallChallenge(
            sequence: nextMacHostedCallChallengeSequence,
            callEpochNonce: epoch
        )
        nextMacHostedCallChallengeSequence &+= 1
        macHostedCallEpochNonce = epoch
        macHostedCallChallenge = challenge
        return challenge
    }

    private func scheduleMacHostedCallPreflightRetryIfNeeded() {
        guard isPrepared,
              transportIsHealthy,
              !callActivitySnapshot.hasNonEndedCall,
              !microphoneInterruptionIsActive,
              !isInterrupted,
              !mediaServicesAreLost,
              let challenge = macHostedCallChallenge,
              challenge.isValid,
              armedMacHostedCallPreflightChallenge != challenge,
              macHostedCallPreflightRetryTask == nil else {
            return
        }
        #if DEBUG
        let retryWaiter = debugMacHostedCallPreflightRetryWaiter
        #else
        let retryWaiter: (() async -> Void)? = nil
        #endif
        macHostedCallPreflightRetryTask = Task { @MainActor [weak self, retryWaiter] in
            guard await Self.waitForMacHostedCallPreflightRetry(
                debugWaiter: retryWaiter
            ) else {
                return
            }
            guard let self,
                  isPrepared,
                  transportIsHealthy,
                  !callActivitySnapshot.hasNonEndedCall,
                  !microphoneInterruptionIsActive,
                  !isInterrupted,
                  !mediaServicesAreLost,
                  macHostedCallChallenge == challenge,
                  armedMacHostedCallPreflightChallenge != challenge else {
                return
            }
            macHostedCallPreflightRetryTask = nil
            let replacement = reserveFreshMacHostedCallPreflight()
            onMacHostedCallChallengeChanged?(replacement)
            scheduleMacHostedCallPreflightRetryIfNeeded()
        }
    }

    private func cancelMacHostedCallPreflightRetry() {
        macHostedCallPreflightRetryTask?.cancel()
        macHostedCallPreflightRetryTask = nil
    }

    private static func waitForMacHostedCallPreflightRetry(
        debugWaiter: (() async -> Void)?
    ) async -> Bool {
        #if DEBUG
        if let debugWaiter {
            await debugWaiter()
            return !Task.isCancelled
        }
        #endif
        do {
            try await Task.sleep(
                for: Self.macHostedCallPreflightRetryDelay
            )
            return true
        } catch {
            return false
        }
    }

    #if DEBUG
    func debugInstallMacHostedCallPreflightRetryWaiter(
        _ waiter: (() async -> Void)?
    ) {
        debugMacHostedCallPreflightRetryWaiter = waiter
    }
    #endif

    private func hostedCallIntersectionHolds(
        _ policy: HostedCallPolicy
    ) -> Bool {
        guard policy.authorization.origin == policy.scope.origin else {
            return false
        }
        switch policy.scope {
        case .startupConnectedCall(let scopeID):
            return currentStartupConnectedCallScope == scopeID
                && !isInterrupted
                && callActivitySnapshot.hasConnectedNonEndedCall
        case .interruption(let interruptionEpoch):
            return currentInterruptionEpoch == interruptionEpoch
                && isInterrupted
                && currentInterruptionReason == .default
                && callActivitySnapshot.hasConnectedNonEndedCall
        }
    }

    private var hostedCallRuntimeGateIsAdmitted: Bool {
        guard
            let policy = hostedCallPolicy,
            policy.runtimeGateIsAdmitted,
            policy.authorization.isValid,
            !policy.authorization.isRecoveryPending,
            hostedCallIntersectionHolds(policy),
            policy.scope.origin != .interruption
                || !hostedCallPolicyIsClosedForCurrentInterruption,
            !requiresExplicitResume,
            !waitsForConnectedCallToEndBeforeRecovery
        else {
            return false
        }
        return true
    }

    private var isPlaying: Bool {
        shouldEnableRemoteAudio && runtimePlayoutIsReady
    }

    /// Open the decoded-track gate so RemoteIO can produce the callbacks that constitute runtime
    /// proof. Background/Now Playing status still waits for `runtimePlayoutIsReady` above.
    private var shouldEnableRemoteAudio: Bool {
        isPrepared
            && playbackIsReady
            && hasRemoteAudio
            && transportIsHealthy
            && !mediaServicesAreLost
            && (
                hostedCallPolicy == nil
                    ? !isInterrupted
                    : hostedCallRuntimeGateIsAdmitted
            )
            && !requiresExplicitResume
            && !waitsForConnectedCallToEndBeforeRecovery
    }

    private var stateText: String {
        guard isPrepared else { return "Inactive" }
        if isInterrupted && !hostedCallRuntimeGateIsAdmitted {
            return "Interrupted"
        }
        if requiresExplicitResume { return "Paused — resume audio" }
        if let policy = hostedCallPolicy,
           policy.scope.origin == .startupConnectedCall,
           !hostedCallRuntimeGateIsAdmitted {
            return "Starting playback"
        }
        if !playbackIsReady { return "Playback unavailable" }
        if !hasRemoteAudio { return "Waiting for Mac audio" }
        if !transportIsHealthy { return "Reconnecting audio" }
        if !runtimePlayoutIsReady { return "Starting playback" }
        if isCallActive { return "Playing — iPhone call may reduce quality" }
        return "Playing"
    }

    private func publishSnapshot() {
        let snapshot = snapshot
        remoteAudioControl?.setEnabled(shouldEnableRemoteAudio)
        if isPrepared {
            backgroundPlayback.publishLiveStream(
                serverName: serverName,
                isPlaying: snapshot.isPlaying
            )
        }
        onSnapshotChanged?(snapshot)
    }

    private func authorizeStartupConnectedCallPolicy() {
        guard
            isPrepared,
            hostedCallPolicy == nil,
            expectedAudioCategoryTransition == nil,
            completedAudioCategoryTransition == nil,
            !isInterrupted,
            callActivitySnapshot.hasConnectedNonEndedCall,
            !mediaServicesAreLost,
            !requiresExplicitResume,
            !waitsForConnectedCallToEndBeforeRecovery
        else {
            return
        }

        let scopeID = UUID()
        currentStartupConnectedCallScope = scopeID
        issueHostedCallPolicy(
            scope: .startupConnectedCall(scopeID)
        )
    }

    private func authorizeHostedCallPolicyIfEligible(
        admissiblePredecessorOperationID: UUID? = nil
    ) {
        guard
            isPrepared,
            hostedCallPolicy == nil,
            !hostedCallPolicyWasIssuedForCurrentInterruption,
            !hostedCallPolicyIsClosedForCurrentInterruption,
            expectedAudioCategoryTransition == nil,
            completedAudioCategoryTransition == nil,
            let currentInterruptionEpoch,
            isInterrupted,
            currentInterruptionReason == .default,
            callActivitySnapshot.hasConnectedNonEndedCall,
            !mediaServicesAreLost,
            !requiresExplicitResume,
            !waitsForConnectedCallToEndBeforeRecovery
        else {
            return
        }

        issueHostedCallPolicy(
            scope: .interruption(currentInterruptionEpoch),
            admissiblePredecessorOperationID:
                admissiblePredecessorOperationID
        )
        hostedCallPolicyWasIssuedForCurrentInterruption =
            hostedCallPolicy != nil
    }

    private func issueHostedCallPolicy(
        scope: HostedCallScope,
        admissiblePredecessorOperationID: UUID? = nil
    ) {
        let policyID = UUID()
        let authorization =
            WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: policyID,
                origin: scope.origin
            )
        hostedCallPolicy = HostedCallPolicy(
            scope: scope,
            authorization: authorization,
            runtimeGateIsAdmitted: false
        )
        _ = installExpectedAudioCategoryTransition(
            operationID: policyID,
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.hostedCallCategoryOptionsRawValue,
            purpose: .hostedCall,
            outputOnlyToken: nil,
            hostedCallPolicyID: policyID,
            admissiblePredecessorOperationID:
                admissiblePredecessorOperationID
        )

        // The native hosted path also requires the default route-sharing policy; that invariant is
        // owned by the exact native authorization supplied to the proof layer.
        onHostedCallPlayoutRecoveryRequested?(authorization)
    }

    private func revokeHostedCallPolicy() {
        let policy = hostedCallPolicy
        let hadHostedOwnership =
            policy != nil
            || expectedAudioCategoryTransition?.purpose
                == .hostedCall
        if case .startupConnectedCall(let scopeID)? = policy?.scope,
           currentStartupConnectedCallScope == scopeID {
            currentStartupConnectedCallScope = nil
        }
        policy?.authorization.revoke()
        hostedCallPolicy = nil
        if expectedAudioCategoryTransition?.purpose
            == .hostedCall {
            _ = cancelExpectedAudioCategoryTransition(
                purpose: .hostedCall,
                terminalCleanup: true
            )
        }
        guard hadHostedOwnership else { return }
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
    }
}
