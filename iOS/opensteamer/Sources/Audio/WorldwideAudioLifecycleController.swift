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

/// Exact reducer/native capability staged before one recovery is allowed to open WebRTC's manual
/// audio gate. Runtime proof and native terminal acknowledgement must both carry this operation.
struct WorldwideAudioRecoveryTransaction: Sendable {
    let operation: AudioTransactionOperationReceipt
    let proof: AudioTransactionProofReceipt
    let authorization: WebRTCIOSPlayoutRecoveryAuthorization
}

/// Native category ingress may release one retired reducer tombstone only after the exact tagged
/// operation has crossed its ordered observation-delivery barrier.
struct WorldwideAudioTransactionDrainRequest: Equatable, Sendable {
    let operation: AudioTransactionOperationReceipt
    let tagGeneration: UInt64
}

/// One exact, one-shot handoff from a completed native output-only microphone teardown back to
/// the lifecycle recovery path. The VM may consume it only after its async task still owns the
/// current peer/session teardown.
@MainActor
final class WorldwideDeferredAudioRecoveryResumeReceipt {
    fileprivate let outputOnlyTokenID: UUID
    fileprivate let outputOnlyOperationID: UUID
    fileprivate let ownerEpoch: UUID
    fileprivate let lifecycleGeneration: UInt64
    fileprivate let microphoneTopologyGeneration: UInt64
    fileprivate let audioOperationEpoch: UInt64
    fileprivate let successorBoundary: AudioTransactionBoundaryReceipt?
    fileprivate let postCallRecoveryMilestone:
        WorldwidePostCallMicrophoneRecoveryMilestone?
    fileprivate let requiresRemoteAudio: Bool
    fileprivate let context: String
    private var wasConsumed = false

    fileprivate init(
        token: WebRTCIOSOutputOnlyMicrophoneToken,
        microphoneTopologyGeneration: UInt64,
        audioOperationEpoch: UInt64,
        successorBoundary: AudioTransactionBoundaryReceipt?,
        postCallRecoveryMilestone:
            WorldwidePostCallMicrophoneRecoveryMilestone?,
        requiresRemoteAudio: Bool,
        context: String
    ) {
        outputOnlyTokenID = token.tokenID
        outputOnlyOperationID = token.operationID
        ownerEpoch = token.ownerEpoch
        lifecycleGeneration = token.lifecycleGeneration
        self.microphoneTopologyGeneration =
            microphoneTopologyGeneration
        self.audioOperationEpoch = audioOperationEpoch
        self.successorBoundary = successorBoundary
        self.postCallRecoveryMilestone =
            postCallRecoveryMilestone
        self.requiresRemoteAudio = requiresRemoteAudio
        self.context = context
    }

    fileprivate func claim() -> Bool {
        guard !wasConsumed else { return false }
        wasConsumed = true
        return true
    }
}

enum WorldwideIPhoneMicrophoneOutputOnlyCompletion {
    case noDeferredRecovery
    case recoveryReady(
        WorldwideDeferredAudioRecoveryResumeReceipt
    )
    case recoveryFailed
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
    /// Synchronously stages the exact app operation into the current peer/native device before
    /// `playback.recover()` may open WebRTC's process-wide audio gate. Nil is fail-closed.
    var onPlayoutRecoveryTransactionStagingRequested:
        ((WebRTCIOSAudioTransactionContext, Bool)
            -> WebRTCIOSPlayoutRecoveryAuthorization?)?
    /// Starts the asynchronous native acknowledgement/runtime proof using the exact capability
    /// that was staged before the synchronous playback effect.
    var onTransactionalPlaybackRecoveryRequested:
        ((WorldwideAudioRecoveryTransaction) -> Void)?
    /// Requests the native ordered-drain barrier only after the reducer has retired this exact
    /// application operation. The resulting receipt is evidence for garbage collection only.
    var onAudioTransactionDrainRequested:
        ((WorldwideAudioTransactionDrainRequest) -> Bool)?
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
    private let audioTransactionAuthority:
        AudioTransactionAuthority
    private var audioTransactionDeviceBinding:
        WebRTCIOSAudioTransactionDeviceBinding?
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
    /// Exact user-owned input recovery while the private-route playback latch stays armed. The
    /// recovery operation ID prevents a superseded native B proof from admitting microphone A.
    private enum MicrophonePlaybackPauseResumeState: Equatable {
        case notRequired
        case required(boundaryID: UUID)
        case recovering(boundaryID: UUID, operationID: UUID?)
        case allowed(boundaryID: UUID)
    }
    private var microphonePlaybackPauseResumeState:
        MicrophonePlaybackPauseResumeState = .notRequired
    private struct PendingDeferredRecovery {
        let operationID: UUID
        let requiresRemoteAudio: Bool
        let context: String
    }
    private struct DeferredRecoveryAdmissionFence {
        let fenceID: UUID
        let requiresRemoteAudio: Bool
        let context: String
    }
    private enum DeferredOutputOnlyRecoveryDisposition: Equatable {
        case awaitingVMValidation(operationID: UUID)
        case retryableAfterValidatedNativeSuccess(operationID: UUID)
        case requiresSessionReconnect(operationID: UUID)

        var operationID: UUID {
            switch self {
            case .awaitingVMValidation(let operationID),
                 .retryableAfterValidatedNativeSuccess(let operationID),
                 .requiresSessionReconnect(let operationID):
                return operationID
            }
        }
    }
    /// Exact C-to-B recovery chain. While present, no reentrant snapshot reconciliation may
    /// readmit microphone A between native output-only teardown and exact recovery proof.
    private var pendingDeferredRecovery: PendingDeferredRecovery?
    /// Installed before proof invalidation calls back into the VM. The callback may synchronously
    /// arm C, so admission must already be closed before that operation is visible to observers.
    private var deferredRecoveryAdmissionFence:
        DeferredRecoveryAdmissionFence?
    /// C's terminal token is not proof that the asynchronous VM teardown still owns the current
    /// peer/session or that the enclosing native disable succeeded. Only the VM may advance this
    /// disposition after checking those facts.
    private var deferredOutputOnlyRecoveryDisposition:
        DeferredOutputOnlyRecoveryDisposition?
    private var mediaServicesAreLost = false
    private var playbackErrorText: String?
    private var playbackDiagnosticText: String?
    private var serverName = "Mac mini"
    private var remoteAudioControl: (any WorldwideRemoteAudioControlling)?
    private var microphoneTopologyGeneration: UInt64 = 0
    private var microphoneTopologyIsEnabled = false
    private struct EstablishedMicrophoneTopologyIdentity {
        let authorization: WebRTCIOSMicrophoneAuthorization
        let generation: UInt64
        let operationID: UUID
    }
    /// Runtime proof retires topology A from the reducer while its native microphone carrier
    /// deliberately remains live. Retain that exact identity until the next topology boundary so
    /// passive A-to-B recovery can preserve the established input without manufacturing C.
    private var establishedMicrophoneTopologyIdentity:
        EstablishedMicrophoneTopologyIdentity?
    private var expectedAudioCategoryTransition:
        ExpectedAudioCategoryTransition?
    private var completedAudioCategoryTransition:
        ExpectedAudioCategoryTransition?
    /// The most recent immutable reducer boundary remains reusable for exactly one successor CAS.
    /// A reentrant successor may consume it first; the outer successor then rejects stale without
    /// touching that newer operation.
    private var pendingAudioTransactionBoundary:
        AudioTransactionBoundaryReceipt?
    private var retiredAudioTransactionOperations:
        Set<AudioTransactionOperationReceipt> = []
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
        let transactionOperation:
            AudioTransactionOperationReceipt?
        let transactionProof: AudioTransactionProofReceipt?
        var microphoneAuthorization:
            WebRTCIOSMicrophoneAuthorization?
        var recoveryAuthorization:
            WebRTCIOSPlayoutRecoveryAuthorization?
        var transactionTagGeneration: UInt64?
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
            WorldwideCallActivityObserver(),
        audioTransactionAuthority:
            AudioTransactionAuthority = AudioTransactionAuthority()
    ) {
        self.playback = playback
        self.backgroundPlayback = backgroundPlayback
        self.events = events
        self.callActivity = callActivity
        self.audioTransactionAuthority =
            audioTransactionAuthority

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

    var microphoneRequiresExplicitResume: Bool {
        guard requiresExplicitResume else { return false }
        if case .allowed = microphonePlaybackPauseResumeState {
            return !playbackIsReady
        }
        return !isMicrophoneResumeRecoveryInProgress
    }

    var isMicrophoneResumeRecoveryInProgress: Bool {
        guard requiresExplicitResume else { return false }
        if case .recovering = microphonePlaybackPauseResumeState {
            return true
        }
        return false
    }

    var microphoneWaitsForDeferredAudioRecovery: Bool {
        pendingDeferredRecovery != nil
            || deferredRecoveryAdmissionFence != nil
    }

    var audioRecoveryRequiresSessionReconnect: Bool {
        if deferredRecoveryAdmissionFence != nil { return true }
        if case .requiresSessionReconnect =
            deferredOutputOnlyRecoveryDisposition {
            return true
        }
        return false
    }

    var postCallMicrophoneRecoveryMilestone:
        WorldwidePostCallMicrophoneRecoveryMilestone? {
        pendingPostCallMicrophoneRecoveryMilestone
    }

    /// Microphone A/C/B operations are admitted only after the current native device namespace
    /// has been bound to the reducer. This is an ownership fact, not a device-availability guess.
    var hasBoundIOSAudioTransactionDevice: Bool {
        audioTransactionDeviceBinding != nil
    }

    /// Establishes the exact native receipt namespace before any A/C/B operation can enter the
    /// Rust reducer. The preceding peer's ordered teardown must already have been consumed.
    @discardableResult
    func bindIOSAudioTransactionDevice(
        _ binding: WebRTCIOSAudioTransactionDeviceBinding
    ) -> Bool {
        guard binding.deviceInstanceGeneration != 0,
              binding.observationRegistrationGeneration != 0,
              audioTransactionDeviceBinding == nil,
              expectedAudioCategoryTransition?
                .transactionOperation == nil,
              completedAudioCategoryTransition?
                .transactionOperation == nil,
              retiredAudioTransactionOperations.isEmpty,
              let snapshot = audioTransactionAuthority.snapshot,
              snapshot.currentOperation == nil,
              snapshot.deviceInstanceGeneration == 0,
              snapshot.observationRegistrationGeneration == 0 else {
            return false
        }
        let decision = audioTransactionAuthority.bindDevice(
            binding,
            expectedReducerRevision: snapshot.reducerRevision
        )
        guard case .deviceBound(let boundSnapshot) = decision,
              boundSnapshot.deviceInstanceGeneration
                == binding.deviceInstanceGeneration,
              boundSnapshot.observationRegistrationGeneration
                == binding.observationRegistrationGeneration else {
            recordAudioTransactionFailure(
                decision,
                context: "bind native audio device"
            )
            return false
        }
        audioTransactionDeviceBinding = binding
        return true
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
        microphonePlaybackPauseResumeState = .notRequired
        pendingDeferredRecovery = nil
        deferredRecoveryAdmissionFence = nil
        deferredOutputOnlyRecoveryDisposition = nil
        mediaServicesAreLost = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        establishedMicrophoneTopologyIdentity?.authorization.revoke()
        establishedMicrophoneTopologyIdentity = nil
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
        if case .recovering(_, nil) =
            microphonePlaybackPauseResumeState {
            // The user may have requested input-only recovery while an asynchronous route-loss
            // teardown still owned C. Transport suspension can take over and finish that same C;
            // fresh transport health must resume the exact pending boundary instead of leaving it
            // parked behind the playback privacy latch.
            _ = dispatchPendingMicrophonePlaybackPauseRecoveryIfPossible()
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
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            closePlaybackGatesAndInvalidateProof()
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

    @discardableResult
    func appBecameActive(
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil
    ) -> Bool {
        guard isPrepared else { return false }
        backgroundPlayback.endTransitionTask()
        let recoveryWasDispatched = recoverPlayback(
            context: "Audio foreground recovery failed",
            preservingEstablishedMicrophoneAuthorization:
                preservingEstablishedMicrophoneAuthorization
        )
        if !recoveryWasDispatched,
           let preservingEstablishedMicrophoneAuthorization {
            failClosedAfterPassiveMicrophoneHandoffFailure(
                preservingEstablishedMicrophoneAuthorization
            )
        }
        return recoveryWasDispatched
    }

    func appBecameInactive() {
        guard isPrepared else { return }
        backgroundPlayback.beginTransitionTask()
        publishSnapshot()
    }

    @discardableResult
    func appEnteredBackground(
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil
    ) -> Bool {
        guard isPrepared else { return false }
        backgroundPlayback.beginTransitionTask()
        let recoveryWasDispatched = recoverPlayback(
            context: "Background audio recovery failed",
            preservingEstablishedMicrophoneAuthorization:
                preservingEstablishedMicrophoneAuthorization
        )
        if !recoveryWasDispatched,
           let preservingEstablishedMicrophoneAuthorization {
            failClosedAfterPassiveMicrophoneHandoffFailure(
                preservingEstablishedMicrophoneAuthorization
            )
        }
        return recoveryWasDispatched
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
        microphonePlaybackPauseResumeState = .notRequired
        pendingDeferredRecovery = nil
        deferredRecoveryAdmissionFence = nil
        deferredOutputOnlyRecoveryDisposition = nil
        mediaServicesAreLost = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        establishedMicrophoneTopologyIdentity?.authorization.revoke()
        establishedMicrophoneTopologyIdentity = nil
        if hadActiveCall {
            onCallActivityChanged?(false)
        }
        onMacHostedCallChallengeChanged?(nil)
        publishSnapshot()
    }

    /// Explicit user recovery for interruptions or route removals where iOS declined automatic
    /// resume. Merely receiving more network packets must never clear this gate.
    @discardableResult
    func resumePlayback(
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil
    ) -> Bool {
        guard isPrepared,
              !mediaServicesAreLost,
              !hostedCallPolicyIsClosedForCurrentInterruption
        else {
            return false
        }
        synchronizeLiveCallStateIfNeeded()
        guard !waitsForConnectedCallToEndBeforeRecovery else {
            publishSnapshot()
            return false
        }
        requiresExplicitResume = false
        microphonePlaybackPauseResumeState = .notRequired
        if playbackIsReady, runtimePlayoutIsReady {
            publishSnapshot()
            return true
        }
        return recoverPlayback(
            context: "Audio resume failed",
            preservingEstablishedMicrophoneAuthorization:
                preservingEstablishedMicrophoneAuthorization,
            coalesceCurrentLiveRecovery: true
        )
    }

    /// Explicitly rebuilds the process-wide RemoteIO path for microphone input without clearing
    /// the private-route playback latch. `shouldEnableRemoteAudio` therefore remains false until
    /// the separate Resume Audio action succeeds.
    @discardableResult
    func resumeMicrophoneInput(
        deferRecoveryUntilNativeTeardownCompletes: Bool = false
    ) -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        guard requiresExplicitResume else {
            return microphoneActivationIsAllowed()
        }
        guard transportIsHealthy,
              hostedCallPolicy == nil,
              microphoneCallDisposition != .blocked,
              !microphoneInterruptionIsActive,
              !isInterrupted,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return false
        }

        switch microphonePlaybackPauseResumeState {
        case .required(let boundaryID):
            microphonePlaybackPauseResumeState = .recovering(
                boundaryID: boundaryID,
                operationID: nil
            )
        case .recovering:
            return true
        case .allowed(let boundaryID):
            if playbackIsReady {
                return microphoneActivationIsAllowed()
            }
            // A later fail-closed boundary may invalidate playback after the input-only recovery
            // was admitted. Keep the advertised Resume Microphone action executable even if an
            // older caller failed to revoke the allowance at the same boundary.
            microphonePlaybackPauseResumeState = .recovering(
                boundaryID: boundaryID,
                operationID: nil
            )
        case .notRequired:
            let boundaryID = UUID()
            microphonePlaybackPauseResumeState = .recovering(
                boundaryID: boundaryID,
                operationID: nil
            )
        }
        publishSnapshot()
        if deferRecoveryUntilNativeTeardownCompletes {
            return true
        }
        return dispatchPendingMicrophonePlaybackPauseRecoveryIfPossible()
    }

    func cancelPendingMicrophoneInputResume() {
        guard case let .recovering(boundaryID, operationID) =
                microphonePlaybackPauseResumeState else {
            return
        }
        microphonePlaybackPauseResumeState = .required(
            boundaryID: boundaryID
        )
        if let operationID,
           expectedAudioCategoryTransition?.operationID == operationID,
           expectedAudioCategoryTransition?.purpose == .recovery {
            closePlaybackGatesAndInvalidateProof()
            _ = cancelExpectedAudioCategoryTransition(
                operationID: operationID,
                purpose: .recovery,
                terminalCleanup: true
            )
        }
        publishSnapshot()
    }

    /// Redrives a one-tap microphone recovery after the route-loss teardown finishes. The pending
    /// boundary remains exact, so a late completion from a retired teardown cannot admit input.
    @discardableResult
    func resumePendingMicrophoneInputIfPossible() -> Bool {
        guard isPrepared else { return false }
        return dispatchPendingMicrophonePlaybackPauseRecoveryIfPossible()
    }

    @discardableResult
    private func dispatchPendingMicrophonePlaybackPauseRecoveryIfPossible()
        -> Bool {
        guard case let .recovering(boundaryID, operationID) =
                microphonePlaybackPauseResumeState,
              operationID == nil else {
            return isMicrophoneResumeRecoveryInProgress
        }
        guard transportIsHealthy,
              hostedCallPolicy == nil,
              microphoneCallDisposition != .blocked,
              !microphoneInterruptionIsActive,
              !isInterrupted,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            microphonePlaybackPauseResumeState = .required(
                boundaryID: boundaryID
            )
            publishSnapshot()
            return false
        }
        if playbackIsReady,
           !playback.requiresRuntimePlayoutProof || runtimePlayoutIsReady {
            microphonePlaybackPauseResumeState = .allowed(
                boundaryID: boundaryID
            )
            publishSnapshot()
            return true
        }

        let recoveryWasDispatched = recoverPlayback(
            context: "Explicit iPhone microphone recovery failed",
            explicitMicrophoneResumeBoundaryID: boundaryID
        )
        if !recoveryWasDispatched,
           case .recovering(let currentBoundaryID, nil) =
                microphonePlaybackPauseResumeState,
           currentBoundaryID == boundaryID {
            microphonePlaybackPauseResumeState = .required(
                boundaryID: boundaryID
            )
            publishSnapshot()
        }
        return recoveryWasDispatched
    }

    /// One guarded automatic rebuild for an already-proven native path whose realtime counters
    /// stopped. This never clears an explicit-resume privacy boundary and never substitutes for
    /// the user's route choice after a private output disappears.
    @discardableResult
    func requestAutomaticRuntimeAudioRecovery() -> Bool {
        requestAutomaticRuntimeRecovery(
            requiresRemoteAudio: true,
            context: "Automatic iPhone audio liveness recovery failed"
        )
    }

    /// The microphone sender can remain useful in a session that has no negotiated Mac-audio
    /// downlink. Preserve the same privacy and interruption gates as ordinary audio recovery, but
    /// bind eligibility to the app-owned microphone topology instead of a remote audio track.
    @discardableResult
    func requestAutomaticRuntimeMicrophoneRecovery() -> Bool {
        requestAutomaticRuntimeRecovery(
            requiresRemoteAudio: false,
            requiresMicrophoneTopology: true,
            context: "Automatic iPhone microphone liveness recovery failed"
        )
    }

    /// One bounded output-only rebuild after native microphone staging reports that RemoteIO was
    /// not ready. The failed authorization has already been retired, so this recovery deliberately
    /// does not require an active microphone topology; the caller may readmit only after success.
    @discardableResult
    func requestAutomaticMicrophoneAdmissionRecovery() -> Bool {
        requestAutomaticRuntimeRecovery(
            requiresRemoteAudio: false,
            requiresMicrophoneTopology: false,
            context: "Automatic iPhone microphone startup recovery failed"
        )
    }

    /// Converts a proof layer's recovery requirement into one reducer-owned B operation. Unlike
    /// the legacy controller test seam, this entry point never falls back to an untagged native
    /// request when the current peer/device callbacks are absent or only partially installed.
    @discardableResult
    func requestTransactionalRuntimePlayoutRecovery(
        requiresRemoteAudio: Bool
    ) -> Bool {
        guard audioTransactionDeviceBinding != nil,
              onPlayoutRecoveryTransactionStagingRequested != nil,
              onTransactionalPlaybackRecoveryRequested != nil else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playback.prepareManualAudioDisabled()
            playbackErrorText =
                "Screen and control are still available. The iPhone audio transaction path is unavailable."
            playbackDiagnosticText =
                "A runtime recovery proof was requested without an exact bound native transaction stream."
            publishSnapshot()
            return false
        }
        return requestAutomaticRuntimeRecovery(
            requiresRemoteAudio: requiresRemoteAudio,
            requiresMicrophoneTopology: false,
            context: "Transactional iPhone playout proof recovery failed"
        )
    }

    @discardableResult
    private func requestAutomaticRuntimeRecovery(
        requiresRemoteAudio: Bool,
        requiresMicrophoneTopology: Bool = true,
        context: String
    ) -> Bool {
        guard deferredRecoveryAdmissionFence == nil else {
            publishSnapshot()
            return false
        }
        var shouldRedriveRetiredRecoveryDrain = false
        if let pendingDeferredRecovery {
            let transition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition
            if transition?.purpose == .recovery,
               transition?.operationID
                    == pendingDeferredRecovery.operationID,
               let transition {
                let transactionIsRetired =
                    transition.transactionOperation.map {
                        retiredAudioTransactionOperations.contains($0)
                    } == true
                if nativeOperationIsCurrent(transition),
                   transactionIsRetired {
                    // A failed native B may have crossed the reducer boundary while its ordered
                    // drain was refused. It is no longer live work to coalesce; the retry below
                    // must redrive that exact drain before staging a fresh B.
                    shouldRedriveRetiredRecoveryDrain = true
                } else if nativeOperationIsCurrent(transition),
                          transition.transactionOperation == nil
                            || (transition.recoveryAuthorization?.isValid
                                    == true
                                || (transition.recoveryAuthorization?
                                        .hasAcceptedTerminalOutcome == true
                                    && transition.recoveryAuthorization?
                                        .terminalReceipt?
                                        .policyMatchesRequestedTarget
                                        == true)) {
                    publishSnapshot()
                    return true
                }
            }
            if !shouldRedriveRetiredRecoveryDrain,
               transition?.purpose == .outputOnlyMicrophone,
               transition?.operationID
                    == pendingDeferredRecovery
                        .operationID,
               let token = transition?.outputOnlyToken,
               token.operationID == transition?.operationID,
               token.state == .armed
                    || token.state == .executing
                    || token.state == .succeeded {
                // Mic and playout liveness observers may report the same RemoteIO freeze. The
                // first exact C owns the shared rebuild; later requests coalesce instead of
                // revoking C or staging B before its native teardown completes.
                publishSnapshot()
                return true
            }
            if !shouldRedriveRetiredRecoveryDrain {
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                playbackDiagnosticText =
                    "The pending audio recovery lost its exact microphone teardown."
                publishSnapshot()
                return false
            }
        }
        let hasEligibleRealtimePath = requiresRemoteAudio
            ? hasRemoteAudio
            : (!requiresMicrophoneTopology
                || microphoneTopologyIsEnabled)
        guard isPrepared,
              hasEligibleRealtimePath,
              transportIsHealthy,
              hostedCallPolicy == nil,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return false
        }

        let expectsAsynchronousMicrophoneTeardown =
            microphoneTopologyIsEnabled
                && onAudioProofInvalidated != nil
        let retiringTransaction = (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?
            .transactionOperation
        guard retireExpectedAudioCategoryTransitionForBoundary() else {
            pendingDeferredRecovery = nil
            deferredOutputOnlyRecoveryDisposition = nil
            closePlaybackGatesAndInvalidateProof()
            playbackDiagnosticText =
                "The automatic audio recovery could not retire its exact native transaction."
            publishSnapshot()
            return false
        }
        let recoveryBoundary: AudioTransactionBoundaryReceipt?
        if let boundary = pendingAudioTransactionBoundary,
           boundary.blocker == retiringTransaction {
            recoveryBoundary = boundary
        } else {
            recoveryBoundary = nil
        }
        _ = advanceMicrophoneTopologyGeneration()
        closePlaybackGatesAndInvalidateProof(
            deferredRecoveryContext:
                expectsAsynchronousMicrophoneTeardown
                    ? context
                    : nil,
            deferredRecoveryRequiresRemoteAudio:
                requiresRemoteAudio
        )
        if let transition = expectedAudioCategoryTransition,
           transition.purpose == .outputOnlyMicrophone,
           let token = transition.outputOnlyToken,
           token.operationID == transition.operationID,
           token.state == .armed || token.state == .executing {
            pendingDeferredRecovery =
                PendingDeferredRecovery(
                    operationID: transition.operationID,
                    requiresRemoteAudio: requiresRemoteAudio,
                    context: context
                )
            if deferredOutputOnlyRecoveryDisposition?.operationID
                != transition.operationID {
                deferredOutputOnlyRecoveryDisposition =
                    .awaitingVMValidation(
                        operationID: transition.operationID
                    )
            }
            publishSnapshot()
            return true
        }
        guard !expectsAsynchronousMicrophoneTeardown else {
            playbackDiagnosticText =
                "The automatic audio recovery could not arm its exact microphone teardown."
            publishSnapshot()
            return false
        }
        publishSnapshot()
        return recoverPlayback(
            context: context,
            proofAlreadyInvalidated: true,
            successorBoundary: recoveryBoundary
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
        guard installExpectedAudioCategoryTransition(
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
        ) != nil else {
            microphoneTopologyIsEnabled = false
            return 0
        }
        if isEnabled, requiresExplicitResume {
            // B proved the output-only path. Enabling A changes the native policy to
            // play-and-record, so Resume Audio must obtain fresh proof for that exact topology
            // before decoded Mac audio can leave the speaker privacy gate.
            runtimePlayoutIsReady = false
        }
        return generation
    }

    @discardableResult
    func bindCurrentMicrophoneTopologyTransaction(
        to authorization: WebRTCIOSMicrophoneAuthorization,
        generation: UInt64
    ) -> Bool {
        guard let transition = expectedAudioCategoryTransition,
              transition.purpose == .topology,
              transition.generation == generation,
              transition.category
                == AVAudioSession.Category.playAndRecord.rawValue,
              let transactionOperation =
                transition.transactionOperation,
              transactionOperation.operationID
                == transition.operationID,
              authorization.bindTransaction(
                transactionOperation.nativeContext
              ) else {
            return false
        }
        expectedAudioCategoryTransition?
            .microphoneAuthorization = authorization
        return true
    }

    /// A failed pre-effect authorization bind means the newly armed A operation was never handed
    /// to a native carrier. Remove it through the reducer's exact unpublished-abort path so
    /// repeated stage failures cannot consume tombstone capacity.
    @discardableResult
    func abortCurrentMicrophoneTopologyTransition(
        generation: UInt64
    ) -> Bool {
        guard let transition = expectedAudioCategoryTransition,
              transition.purpose == .topology,
              transition.generation == generation,
              transition.category
                == AVAudioSession.Category.playAndRecord.rawValue,
              transition.microphoneAuthorization == nil,
              transition.transactionTagGeneration == nil,
              cancelExpectedAudioCategoryTransition(
                operationID: transition.operationID,
                purpose: .topology,
                terminalCleanup: true
              ) else {
            return false
        }
        microphoneTopologyIsEnabled = false
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
        return true
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
        guard installExpectedAudioCategoryTransition(
            operationID: token.operationID,
            category: target.category,
            mode: target.mode,
            categoryOptionsRawValue:
                Self.normalCategoryOptionsRawValue,
            purpose: .outputOnlyMicrophone,
            outputOnlyToken: token,
            admissiblePredecessorOperationID:
                predecessorOperationID
        ) != nil,
              let transition = expectedAudioCategoryTransition,
              transition.operationID == token.operationID else {
            token.revoke()
            return nil
        }
        if let transactionOperation = transition.transactionOperation {
            guard token.bindTransaction(
                transactionOperation.nativeContext
            ) else {
                token.revoke()
                return nil
            }
        } else if audioTransactionDeviceBinding != nil {
            token.revoke()
            return nil
        }
        if let fence = deferredRecoveryAdmissionFence {
            // Bind the provisional admission fence at the same MainActor boundary that makes C
            // visible. No snapshot callback can therefore observe C without also being blocked
            // from re-arming microphone A.
            pendingDeferredRecovery = PendingDeferredRecovery(
                operationID: token.operationID,
                requiresRemoteAudio: fence.requiresRemoteAudio,
                context: fence.context
            )
            deferredOutputOnlyRecoveryDisposition =
                .awaitingVMValidation(operationID: token.operationID)
            deferredRecoveryAdmissionFence = nil
        }
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

    /// Consumes transport-owned C only after the peer and VM have both validated the exact
    /// retirement. This closes C without starting B while transport is still uncertain. If the
    /// ordered drain is temporarily refused, the validated terminal C remains retryable and the
    /// later healthy-transport recovery redrives that same drain before staging B.
    @discardableResult
    func completeValidatedTransportOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        guard isPrepared,
              !transportIsHealthy,
              token.state == .succeeded,
              let transition =
                iPhoneMicrophoneOutputOnlyTransition(token),
              outputOnlyTransitionEpochIsCurrent(transition),
              transition.generation == token.lifecycleGeneration,
              transition.category == token.target.category,
              transition.mode == token.target.mode,
              transition.categoryOptionsRawValue
                == Self.normalCategoryOptionsRawValue else {
            return false
        }

        let deferredRecovery = PendingDeferredRecovery(
            operationID: token.operationID,
            requiresRemoteAudio: false,
            context: "Audio transport recovery failed"
        )
        pendingDeferredRecovery = deferredRecovery
        deferredOutputOnlyRecoveryDisposition =
            .retryableAfterValidatedNativeSuccess(
                operationID: token.operationID
            )
        let transactionOperation = transition.transactionOperation
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)

        let retired = cancelExpectedAudioCategoryTransition(
            operationID: token.operationID,
            purpose: .outputOnlyMicrophone,
            terminalCleanup: true,
            preservingDeferredRecoveryHandoff: true
        )
        pendingDeferredRecovery = deferredRecovery
        guard !retired else {
            publishSnapshot()
            return true
        }

        guard transactionOperation.map({
            retiredAudioTransactionOperations.contains($0)
        }) == true else {
            deferredOutputOnlyRecoveryDisposition =
                .requiresSessionReconnect(
                    operationID: token.operationID
                )
            deferredAudioRecoveryRequiresReconnect(after: token)
            return false
        }
        deferredOutputOnlyRecoveryDisposition =
            .retryableAfterValidatedNativeSuccess(
                operationID: token.operationID
            )
        publishSnapshot()
        return true
    }

    /// Abandons only an exact current C whose owning VM task reached an unproven or failed native
    /// result. A failed carrier can be retired, but it can never be converted into B/A without a
    /// new peer/device namespace.
    @discardableResult
    func abandonCurrentOutputOnlyTransitionRequiringReconnect(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        guard isPrepared,
              token.state != .executing,
              let transition =
                iPhoneMicrophoneOutputOnlyTransition(token),
              transition.generation == token.lifecycleGeneration,
              transition.category == token.target.category,
              transition.mode == token.target.mode,
              transition.categoryOptionsRawValue
                == Self.normalCategoryOptionsRawValue else {
            return false
        }

        let deferredRecovery = PendingDeferredRecovery(
            operationID: token.operationID,
            requiresRemoteAudio: false,
            context:
                "A failed iPhone microphone teardown requires a new session"
        )
        pendingDeferredRecovery = deferredRecovery
        deferredOutputOnlyRecoveryDisposition =
            .requiresSessionReconnect(
                operationID: token.operationID
            )
        _ = cancelExpectedAudioCategoryTransition(
            operationID: token.operationID,
            purpose: .outputOnlyMicrophone,
            terminalCleanup: true,
            preservingDeferredRecoveryHandoff: true
        )
        pendingDeferredRecovery = deferredRecovery
        deferredAudioRecoveryRequiresReconnect(after: token)
        return true
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

    /// Retires one terminal native output-only write. Deferred recovery is returned as a
    /// one-shot receipt instead of being started here: the VM must first prove that the async
    /// native task still owns the current peer, session, and teardown generation.
    @discardableResult
    func iPhoneMicrophoneOutputOnlyTransitionDidComplete(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> WorldwideIPhoneMicrophoneOutputOnlyCompletion {
        // A terminal callback may arrive after a newer route/call boundary has replaced this C.
        // Prove exact reducer ownership before deriving or mutating any deferred recovery state;
        // a stale token must never graft itself onto a newer post-call milestone.
        guard let completingTransition =
                iPhoneMicrophoneOutputOnlyTransition(token) else {
            return .noDeferredRecovery
        }
        guard outputOnlyTransitionEpochIsCurrent(
                completingTransition
              ) else {
            return rejectStaleIPhoneMicrophoneOutputOnlyCompletion(
                token
            )
        }
        var deferredRecovery = pendingDeferredRecovery.flatMap {
            $0.operationID == token.operationID ? $0 : nil
        }
        if deferredRecovery == nil,
           pendingPostCallMicrophoneRecoveryMilestone != nil {
            deferredRecovery = PendingDeferredRecovery(
                operationID: token.operationID,
                requiresRemoteAudio: false,
                context:
                    "Audio recovery after microphone teardown and call end failed"
            )
        }
        if let deferredRecovery {
            // Keep microphone admission fenced across every synchronous snapshot callback until
            // the receipt is consumed and B has become the current exact recovery operation.
            pendingDeferredRecovery = deferredRecovery
            if deferredOutputOnlyRecoveryDisposition?.operationID
                != token.operationID {
                deferredOutputOnlyRecoveryDisposition =
                    .awaitingVMValidation(
                        operationID: token.operationID
                    )
            }
        }
        guard isPrepared else {
            return deferredRecovery == nil
                ? .noDeferredRecovery
                : .recoveryFailed
        }
        guard token.state == .succeeded || token.state == .failed else {
            if deferredRecovery != nil
                || pendingPostCallMicrophoneRecoveryMilestone != nil {
                token.revoke()
                _ = cancelExpectedAudioCategoryTransition(
                    operationID: token.operationID,
                    purpose: .outputOnlyMicrophone,
                    terminalCleanup: true,
                    preservingDeferredRecoveryHandoff: true
                )
                if let deferredRecovery {
                    pendingDeferredRecovery = deferredRecovery
                }
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                if pendingPostCallMicrophoneRecoveryMilestone != nil {
                    playbackErrorText =
                        "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
                    playbackDiagnosticText =
                        "The post-call microphone teardown did not reach a terminal native result."
                }
                publishSnapshot()
                return .recoveryFailed
            }
            return .noDeferredRecovery
        }
        synchronizeLiveCallStateIfNeeded()
        if deferredRecovery == nil,
           pendingPostCallMicrophoneRecoveryMilestone != nil {
            deferredRecovery = PendingDeferredRecovery(
                operationID: token.operationID,
                requiresRemoteAudio: false,
                context:
                    "Audio recovery after microphone teardown and call end failed"
            )
            pendingDeferredRecovery = deferredRecovery
        }
        guard let synchronizedTransition =
                iPhoneMicrophoneOutputOnlyTransition(token) else {
            if deferredRecovery != nil {
                return .recoveryFailed
            }
            return .noDeferredRecovery
        }
        guard outputOnlyTransitionEpochIsCurrent(
                synchronizedTransition
              ) else {
            return rejectStaleIPhoneMicrophoneOutputOnlyCompletion(
                token
            )
        }
        if microphoneCallDisposition == .blocked {
            let retired = cancelExpectedAudioCategoryTransition(
                operationID: token.operationID,
                purpose: .outputOnlyMicrophone,
                terminalCleanup: true,
                preservingDeferredRecoveryHandoff: true
            )
            if let deferredRecovery {
                pendingDeferredRecovery = deferredRecovery
            }
            if retired {
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
            }
            publishSnapshot()
            return deferredRecovery == nil
                ? .noDeferredRecovery
                : .recoveryFailed
        }
        guard pendingPostCallMicrophoneRecoveryMilestone != nil else {
            let retiringTransaction = expectedAudioCategoryTransition?
                .transactionOperation
            let retired = cancelExpectedAudioCategoryTransition(
                operationID: token.operationID,
                purpose: .outputOnlyMicrophone,
                terminalCleanup: true,
                preservingDeferredRecoveryHandoff: true
            )
            if let deferredRecovery {
                pendingDeferredRecovery = deferredRecovery
            }
            guard retired else {
                let explicitMicrophoneResumeCanOwnRetryableC: Bool
                switch microphonePlaybackPauseResumeState {
                case .required, .recovering(_, nil):
                    explicitMicrophoneResumeCanOwnRetryableC =
                        requiresExplicitResume
                case .notRequired, .recovering(_, _), .allowed:
                    explicitMicrophoneResumeCanOwnRetryableC = false
                }
                if deferredRecovery == nil,
                   explicitMicrophoneResumeCanOwnRetryableC {
                    // Private-route C may finish either before or after Resume Microphone is
                    // tapped. If its first ordered drain is refused, bind that exact terminal C
                    // now so the still-owning VM task can validate native success and authorize
                    // a later explicit retry; no future async owner will arrive for this C.
                    let pending = PendingDeferredRecovery(
                        operationID: token.operationID,
                        requiresRemoteAudio: false,
                        context:
                            "Explicit iPhone microphone recovery failed"
                    )
                    pendingDeferredRecovery = pending
                    deferredOutputOnlyRecoveryDisposition =
                        .awaitingVMValidation(
                            operationID: token.operationID
                        )
                    playbackDiagnosticText =
                        "The microphone teardown is waiting for its exact ordered drain before recovery can retry."
                    publishSnapshot()
                    return .recoveryFailed
                }
                if deferredRecovery != nil {
                    playbackDiagnosticText =
                        "The automatic audio recovery could not retire its exact microphone teardown."
                }
                publishSnapshot()
                return deferredRecovery == nil
                    ? .noDeferredRecovery
                    : .recoveryFailed
            }
            if let deferredRecovery {
                guard token.state == .succeeded,
                      transportIsHealthy,
                      hostedCallPolicy == nil,
                      !isInterrupted,
                      !requiresExplicitResume,
                      !waitsForConnectedCallToEndBeforeRecovery,
                      !mediaServicesAreLost else {
                    publishSnapshot()
                    return .recoveryFailed
                }
                let recoveryBoundary: AudioTransactionBoundaryReceipt?
                if let boundary = pendingAudioTransactionBoundary,
                   boundary.blocker == retiringTransaction {
                    recoveryBoundary = boundary
                } else {
                    recoveryBoundary = nil
                }
                let receipt =
                    WorldwideDeferredAudioRecoveryResumeReceipt(
                        token: token,
                        microphoneTopologyGeneration:
                            microphoneTopologyGeneration,
                        audioOperationEpoch: audioOperationEpoch,
                        successorBoundary: recoveryBoundary,
                        postCallRecoveryMilestone: nil,
                        requiresRemoteAudio:
                            deferredRecovery
                                .requiresRemoteAudio,
                        context: deferredRecovery.context
                    )
                publishSnapshot()
                return .recoveryReady(receipt)
            }
            authorizeHostedCallPolicyIfEligible(
                admissiblePredecessorOperationID:
                token.operationID
            )
            publishSnapshot()
            return .noDeferredRecovery
        }
        let postCallRecoveryMilestone =
            pendingPostCallMicrophoneRecoveryMilestone
        let retiringTransaction = (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?
            .transactionOperation
        let retired = cancelExpectedAudioCategoryTransition(
            operationID: token.operationID,
            purpose: .outputOnlyMicrophone,
            terminalCleanup: true,
            preservingDeferredRecoveryHandoff: true
        )
        if let deferredRecovery {
            pendingDeferredRecovery = deferredRecovery
        }
        guard retired,
              token.state == .succeeded,
              let postCallRecoveryMilestone else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackErrorText =
                "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
            playbackDiagnosticText = retired
                ? "The post-call microphone teardown did not complete successfully."
                : "The post-call recovery could not retire its exact microphone teardown."
            publishSnapshot()
            return .recoveryFailed
        }
        let recoveryBoundary: AudioTransactionBoundaryReceipt?
        if let boundary = pendingAudioTransactionBoundary,
           boundary.blocker == retiringTransaction {
            recoveryBoundary = boundary
        } else {
            recoveryBoundary = nil
        }
        let receipt = WorldwideDeferredAudioRecoveryResumeReceipt(
            token: token,
            microphoneTopologyGeneration:
                microphoneTopologyGeneration,
            audioOperationEpoch: audioOperationEpoch,
            successorBoundary: recoveryBoundary,
            postCallRecoveryMilestone:
                postCallRecoveryMilestone,
            requiresRemoteAudio: false,
            context: deferredRecovery?.context
                ?? "Audio recovery after microphone teardown and call end failed"
        )
        publishSnapshot()
        return .recoveryReady(receipt)
    }

    /// The async VM task calls this only after proving current teardown/session/peer ownership and
    /// a successful enclosing native disable. A refused drain can then be retried by the user, but
    /// token success alone never grants that authority.
    @discardableResult
    func authorizeDeferredAudioRecoveryRetryAfterNativeSuccess(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        let transition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        guard isPrepared,
              token.state == .succeeded,
              pendingDeferredRecovery?.operationID
                == token.operationID,
              deferredOutputOnlyRecoveryDisposition
                == .awaitingVMValidation(
                    operationID: token.operationID
                ),
              transition?.purpose == .outputOnlyMicrophone,
              transition?.operationID == token.operationID,
              transition?.outputOnlyToken.map({ $0 === token }) == true,
              let transactionOperation =
                transition?.transactionOperation,
              retiredAudioTransactionOperations
                .contains(transactionOperation) else {
            deferredAudioRecoveryRequiresReconnect(after: token)
            return false
        }
        deferredOutputOnlyRecoveryDisposition =
            .retryableAfterValidatedNativeSuccess(
                operationID: token.operationID
            )
        if requiresExplicitResume,
           case let .recovering(boundaryID, nil) =
            microphonePlaybackPauseResumeState {
            microphonePlaybackPauseResumeState = .required(
                boundaryID: boundaryID
            )
        }
        publishSnapshot()
        return true
    }

    /// A failed enclosing native disable, failed C, or lost handoff cannot be converted into B by
    /// an ordinary retry. Keep the exact chain closed until the session/device namespace reconnects.
    func deferredAudioRecoveryRequiresReconnect(
        after token: WebRTCIOSOutputOnlyMicrophoneToken
    ) {
        guard pendingDeferredRecovery?.operationID
                == token.operationID else {
            return
        }
        deferredOutputOnlyRecoveryDisposition =
            .requiresSessionReconnect(
                operationID: token.operationID
            )
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        playbackErrorText =
            "Screen and control are still available. Reconnect this session to restore iPhone audio."
        playbackDiagnosticText =
            "The native microphone teardown did not produce a retryable exact recovery handoff."
        publishSnapshot()
    }

    /// Consumes the exact C-completion receipt only after the VM has proven ownership of the
    /// asynchronous native teardown. A replay or any intervening lifecycle boundary is rejected.
    @discardableResult
    func resumeDeferredAudioRecovery(
        _ receipt: WorldwideDeferredAudioRecoveryResumeReceipt,
        after token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        guard receipt.outputOnlyTokenID == token.tokenID,
              receipt.outputOnlyOperationID == token.operationID,
              receipt.ownerEpoch == token.ownerEpoch,
              receipt.lifecycleGeneration
                == token.lifecycleGeneration,
              token.state == .succeeded,
              receipt.claim() else {
            return false
        }
        let hasEligibleRealtimePath = receipt.requiresRemoteAudio
            ? hasRemoteAudio
            : true
        guard isPrepared,
              pendingDeferredRecovery?.operationID
                == receipt.outputOnlyOperationID,
              pendingDeferredRecovery?.requiresRemoteAudio
                == receipt.requiresRemoteAudio,
              pendingDeferredRecovery?.context == receipt.context,
              deferredOutputOnlyRecoveryDisposition
                == .awaitingVMValidation(
                    operationID: receipt.outputOnlyOperationID
                ),
              hasEligibleRealtimePath,
              transportIsHealthy,
              hostedCallPolicy == nil,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost,
              !microphoneTopologyIsEnabled,
              microphoneTopologyGeneration
                == receipt.microphoneTopologyGeneration,
              audioOperationEpoch == receipt.audioOperationEpoch,
              expectedAudioCategoryTransition == nil,
              completedAudioCategoryTransition == nil,
              pendingAudioTransactionBoundary
                == receipt.successorBoundary,
              pendingPostCallMicrophoneRecoveryMilestone
                == receipt.postCallRecoveryMilestone else {
            if receipt.postCallRecoveryMilestone != nil {
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                playbackErrorText =
                    "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
                playbackDiagnosticText =
                    "The exact post-call recovery handoff was superseded before it could start."
            }
            publishSnapshot()
            return false
        }
        deferredOutputOnlyRecoveryDisposition = nil
        _ = advanceMicrophoneTopologyGeneration()
        publishSnapshot()
        return recoverPlayback(
            context: receipt.context,
            proofAlreadyInvalidated: true,
            successorBoundary: receipt.successorBoundary
        )
    }

    @discardableResult
    private func armExpectedAudioCategoryTransition(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        purpose: ExpectedAudioCategoryTransitionPurpose,
        successorBoundary: AudioTransactionBoundaryReceipt? = nil,
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil
    ) -> UUID? {
        let predecessorOperationID =
            currentAudioCategoryTransitionOperationID
        if successorBoundary == nil {
            guard cancelExpectedAudioCategoryTransition(
                preservingEstablishedMicrophoneAuthorization:
                    preservingEstablishedMicrophoneAuthorization
            ) else {
                return nil
            }
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
                predecessorOperationID,
            successorBoundary: successorBoundary
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
        admissiblePredecessorOperationID: UUID? = nil,
        successorBoundary: AudioTransactionBoundaryReceipt? = nil
    ) -> UUID? {
        guard expectedAudioCategoryTransition == nil else {
            return nil
        }
        let tracksNativeTransaction =
            audioTransactionDeviceBinding != nil
            && (purpose == .recovery
                || purpose == .outputOnlyMicrophone
                || (purpose == .topology
                    && category
                        == AVAudioSession.Category
                            .playAndRecord.rawValue))
        var transactionOperation:
            AudioTransactionOperationReceipt?
        var transactionProof: AudioTransactionProofReceipt?
        var validatedAdmissiblePredecessorOperationID =
            admissiblePredecessorOperationID
        if tracksNativeTransaction {
            guard let authoritySnapshot =
                    audioTransactionAuthority.snapshot else {
                playbackDiagnosticText =
                    "The audio transaction authority was unavailable."
                return nil
            }
            let target = AudioTransactionTarget(
                category: category,
                mode: mode,
                categoryOptionsRawValue: categoryOptionsRawValue,
                routeSharingPolicyRawValue:
                    Int(
                        AVAudioSession.RouteSharingPolicy.default
                            .rawValue
                    ),
                inputRequired:
                    category
                        == AVAudioSession.Category
                            .playAndRecord.rawValue
            )
            let selectedBoundary = successorBoundary
                ?? pendingAudioTransactionBoundary
            let transactionDecision: AudioTransactionDecision
            if let selectedBoundary {
                transactionDecision =
                    audioTransactionAuthority.armSuccessor(
                        operationID: operationID,
                        target: target,
                        boundary: selectedBoundary,
                        observationHead:
                            authoritySnapshot
                                .lastObservationSequence
                    )
            } else {
                transactionDecision = audioTransactionAuthority.arm(
                    operationID: operationID,
                    target: target,
                    expectedReducerRevision:
                        authoritySnapshot.reducerRevision,
                    observationHead:
                        authoritySnapshot.lastObservationSequence
                )
            }
            guard case let .armed(
                operation,
                proof,
                predecessor
            ) =
                    transactionDecision else {
                recordAudioTransactionFailure(
                    transactionDecision,
                    context: "arm category operation"
                )
                return nil
            }
            transactionOperation = operation
            transactionProof = proof
            // Rust is the sole authority for predecessor lineage. A caller-provided boundary may
            // name a tombstone whose target differs; in that case the reducer intentionally
            // returns nil and the Swift lifecycle must not resurrect the caller's inferred ID.
            validatedAdmissiblePredecessorOperationID =
                predecessor?.operationID
            if pendingAudioTransactionBoundary == selectedBoundary {
                pendingAudioTransactionBoundary = nil
            }
        } else if pendingAudioTransactionBoundary != nil {
            // An untracked but genuine lifecycle boundary must still invalidate an outer
            // successor's CAS. With no current reducer operation this advances authority without
            // creating an undrainable tombstone.
            guard let authoritySnapshot =
                    audioTransactionAuthority.snapshot else {
                return nil
            }
            let decision = audioTransactionAuthority.applyBoundary(
                expectedReducerRevision:
                    authoritySnapshot.reducerRevision,
                observationHead:
                    authoritySnapshot.lastObservationSequence
            )
            guard case .boundaryApplied = decision else {
                recordAudioTransactionFailure(
                    decision,
                    context: "advance untracked category boundary"
                )
                return nil
            }
            pendingAudioTransactionBoundary = nil
        }
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
                validatedAdmissiblePredecessorOperationID,
            transactionOperation: transactionOperation,
            transactionProof: transactionProof,
            microphoneAuthorization: nil,
            recoveryAuthorization: nil,
            transactionTagGeneration: nil
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
        terminalCleanup: Bool = false,
        preservingDeferredRecoveryHandoff: Bool = false,
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil,
        preservingMicrophonePlaybackPauseRecovery: Bool = false
    ) -> Bool {
        if let expectedAudioCategoryTransition {
            guard audioCategoryTransition(
                expectedAudioCategoryTransition,
                matchesOperationID: operationID,
                purpose: purpose
            ) else {
                return false
            }
            if !preservingMicrophonePlaybackPauseRecovery {
                failMicrophonePlaybackPauseRecovery(
                    operationID:
                        expectedAudioCategoryTransition.operationID
                )
            }

            guard retireOutputOnlyTokenIfAdmissible(
                expectedAudioCategoryTransition.outputOnlyToken,
                terminalCleanup: terminalCleanup
            ) else { return false }
            let preservesMicrophoneAuthorization =
                expectedAudioCategoryTransition.purpose == .topology
                    && expectedAudioCategoryTransition.category
                        == AVAudioSession.Category.playAndRecord.rawValue
                    && expectedAudioCategoryTransition.generation
                        == microphoneTopologyGeneration
                    && microphoneTopologyIsEnabled
                    && expectedAudioCategoryTransition
                        .microphoneAuthorization
                        === preservingEstablishedMicrophoneAuthorization
                    && preservingEstablishedMicrophoneAuthorization?
                        .isValid == true
            guard retireAudioTransactionIfCurrent(
                expectedAudioCategoryTransition,
                preserveEstablishedMicrophoneAuthorization:
                    preservesMicrophoneAuthorization
            ) else { return false }
            let orphanedDeferredRecoveryToken =
                !preservingDeferredRecoveryHandoff
                    && expectedAudioCategoryTransition.purpose
                        == .outputOnlyMicrophone
                    && pendingDeferredRecovery?.operationID
                        == expectedAudioCategoryTransition.operationID
                    && deferredOutputOnlyRecoveryDisposition
                        == .awaitingVMValidation(
                            operationID:
                                expectedAudioCategoryTransition
                                    .operationID
                        )
                    ? expectedAudioCategoryTransition.outputOnlyToken
                    : nil

            events.cancelCategoryChangeOperation(
                expectedAudioCategoryTransition.operationID
            )
            if pendingAmbiguousCategoryProof?.transition.operationID
                == expectedAudioCategoryTransition.operationID {
                pendingAmbiguousCategoryProof = nil
            }
            if !preservesMicrophoneAuthorization {
                expectedAudioCategoryTransition
                    .microphoneAuthorization?.revoke()
            }
            expectedAudioCategoryTransition
                .recoveryAuthorization?.revoke()
            clearValidatedDeferredRecoveryDispositionAfterRetiring(
                expectedAudioCategoryTransition
            )
            updateEstablishedMicrophoneTopologyIdentityAfterRetiring(
                expectedAudioCategoryTransition,
                preservesAuthorization: preservesMicrophoneAuthorization
            )
            self.expectedAudioCategoryTransition = nil
            completedAudioCategoryTransition = nil
            _ = advanceAudioOperationEpoch()
            if let orphanedDeferredRecoveryToken {
                deferredAudioRecoveryRequiresReconnect(
                    after: orphanedDeferredRecoveryToken
                )
            }
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
        if !preservingMicrophonePlaybackPauseRecovery {
            failMicrophonePlaybackPauseRecovery(
                operationID:
                    completedAudioCategoryTransition.operationID
            )
        }
        guard retireOutputOnlyTokenIfAdmissible(
            completedAudioCategoryTransition.outputOnlyToken,
            terminalCleanup: terminalCleanup
        ) else { return false }
        let preservesMicrophoneAuthorization =
            completedAudioCategoryTransition.purpose == .topology
                && completedAudioCategoryTransition.category
                    == AVAudioSession.Category.playAndRecord.rawValue
                && completedAudioCategoryTransition.generation
                    == microphoneTopologyGeneration
                && microphoneTopologyIsEnabled
                && completedAudioCategoryTransition
                    .microphoneAuthorization
                    === preservingEstablishedMicrophoneAuthorization
                && preservingEstablishedMicrophoneAuthorization?
                    .isValid == true
        guard retireAudioTransactionIfCurrent(
            completedAudioCategoryTransition,
            preserveEstablishedMicrophoneAuthorization:
                preservesMicrophoneAuthorization
        ) else { return false }
        let orphanedDeferredRecoveryToken =
            !preservingDeferredRecoveryHandoff
                && completedAudioCategoryTransition.purpose
                    == .outputOnlyMicrophone
                && pendingDeferredRecovery?.operationID
                    == completedAudioCategoryTransition.operationID
                && deferredOutputOnlyRecoveryDisposition
                    == .awaitingVMValidation(
                        operationID:
                            completedAudioCategoryTransition.operationID
                    )
                ? completedAudioCategoryTransition.outputOnlyToken
                : nil
        if pendingAmbiguousCategoryProof?.transition.operationID
            == completedAudioCategoryTransition.operationID {
            pendingAmbiguousCategoryProof = nil
        }
        if !preservesMicrophoneAuthorization {
            completedAudioCategoryTransition
                .microphoneAuthorization?.revoke()
        }
        completedAudioCategoryTransition
            .recoveryAuthorization?.revoke()
        clearValidatedDeferredRecoveryDispositionAfterRetiring(
            completedAudioCategoryTransition
        )
        updateEstablishedMicrophoneTopologyIdentityAfterRetiring(
            completedAudioCategoryTransition,
            preservesAuthorization: preservesMicrophoneAuthorization
        )
        self.completedAudioCategoryTransition = nil
        _ = advanceAudioOperationEpoch()
        if let orphanedDeferredRecoveryToken {
            deferredAudioRecoveryRequiresReconnect(
                after: orphanedDeferredRecoveryToken
            )
        }
        return true
    }

    private func retireAudioTransactionIfCurrent(
        _ transition: ExpectedAudioCategoryTransition,
        preserveEstablishedMicrophoneAuthorization: Bool = false
    ) -> Bool {
        guard let operation = transition.transactionOperation else {
            return true
        }
        if retiredAudioTransactionOperations.contains(operation) {
            return requestAudioTransactionDrainIfPossible(
                for: transition
            )
        }
        guard let snapshot = audioTransactionAuthority.snapshot,
              snapshot.currentOperation == operation else {
            playbackDiagnosticText =
                "The audio transaction changed before its boundary could retire."
            return false
        }
        guard nativeAudioTransactionTag(for: transition) != nil else {
            if !preserveEstablishedMicrophoneAuthorization {
                transition.microphoneAuthorization?.revoke()
            }
            transition.recoveryAuthorization?.revoke()
            let decision = audioTransactionAuthority.abortUnpublished(
                operation,
                expectedReducerRevision: snapshot.reducerRevision
            )
            guard case .abortedUnpublished(let aborted) = decision,
                  aborted == operation else {
                recordAudioTransactionFailure(
                    decision,
                    context: "abort unpublished category operation"
                )
                return false
            }
            pendingAudioTransactionBoundary = nil
            return true
        }
        let decision = audioTransactionAuthority.applyBoundary(
            expectedReducerRevision: snapshot.reducerRevision,
            observationHead: snapshot.lastObservationSequence
        )
        guard case let .boundaryApplied(boundary) = decision else {
            recordAudioTransactionFailure(
                decision,
                context: "retire category operation"
            )
            return false
        }
        pendingAudioTransactionBoundary = boundary
        retiredAudioTransactionOperations.insert(operation)
        return requestAudioTransactionDrainIfPossible(for: transition)
    }

    private func requestAudioTransactionDrainIfPossible(
        for transition: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard let operation = transition.transactionOperation,
              let tagGeneration = nativeAudioTransactionTag(
                for: transition
              ),
              tagGeneration != 0 else { return false }
        let request = WorldwideAudioTransactionDrainRequest(
            operation: operation,
            tagGeneration: tagGeneration
        )
        guard onAudioTransactionDrainRequested?(request) == true else {
            playbackDiagnosticText =
                "The native audio transaction drain barrier could not be requested."
            return false
        }
        return true
    }

    private func nativeAudioTransactionTag(
        for transition: ExpectedAudioCategoryTransition
    ) -> UInt64? {
        transition.transactionTagGeneration
            ?? transition.outputOnlyToken?
                .stagedTransactionTagGeneration
            ?? transition.microphoneAuthorization?
                .stagedTransactionTagGeneration
            ?? transition.recoveryAuthorization?
                .stagedTransactionTagGeneration
    }

    func recordNativeAudioTransactionTag(
        _ tagGeneration: UInt64,
        for context: WebRTCIOSAudioTransactionContext
    ) {
        guard tagGeneration != 0 else { return }
        if expectedAudioCategoryTransition?
            .transactionOperation?.nativeContext == context {
            expectedAudioCategoryTransition?
                .transactionTagGeneration = tagGeneration
            if let transition = expectedAudioCategoryTransition,
               let operation = transition.transactionOperation,
               retiredAudioTransactionOperations.contains(operation) {
                _ = requestAudioTransactionDrainIfPossible(
                    for: transition
                )
            }
            return
        }
        if completedAudioCategoryTransition?
            .transactionOperation?.nativeContext == context {
            completedAudioCategoryTransition?
                .transactionTagGeneration = tagGeneration
            if let transition = completedAudioCategoryTransition,
               let operation = transition.transactionOperation,
               retiredAudioTransactionOperations.contains(operation) {
                _ = requestAudioTransactionDrainIfPossible(
                    for: transition
                )
            }
        }
    }

    private func recordAudioTransactionFailure(
        _ decision: AudioTransactionDecision,
        context: String
    ) {
        playbackDiagnosticText =
            "Audio transaction authority rejected \(context): \(String(describing: decision))."
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

    private func iPhoneMicrophoneOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> ExpectedAudioCategoryTransition? {
        let transition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        guard transition?.purpose == .outputOnlyMicrophone,
              transition?.operationID == token.operationID,
              transition?.outputOnlyToken === token else {
            return nil
        }
        return transition
    }

    private func ownsIPhoneMicrophoneOutputOnlyTransition(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        iPhoneMicrophoneOutputOnlyTransition(token) != nil
    }

    private func outputOnlyTransitionEpochIsCurrent(
        _ transition: ExpectedAudioCategoryTransition
    ) -> Bool {
        transition.operationEpoch == audioOperationEpoch
            && transition.generation == microphoneTopologyGeneration
    }

    private func rejectStaleIPhoneMicrophoneOutputOnlyCompletion(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> WorldwideIPhoneMicrophoneOutputOnlyCompletion {
        let hadDeferredRecovery =
            pendingDeferredRecovery?.operationID == token.operationID
        let retired = cancelExpectedAudioCategoryTransition(
            operationID: token.operationID,
            purpose: .outputOnlyMicrophone,
            terminalCleanup: true,
            preservingDeferredRecoveryHandoff: true
        )
        if hadDeferredRecovery || !retired {
            // Even when the stale carrier's ordered drain is temporarily refused, the newer
            // lifecycle epoch permanently forbids converting its terminal result into B. Bind an
            // otherwise unowned retained C before marking it reconnect-only, so the UI cannot offer
            // an explicit retry that this stale carrier can never authorize.
            if !hadDeferredRecovery {
                pendingDeferredRecovery = PendingDeferredRecovery(
                    operationID: token.operationID,
                    requiresRemoteAudio: false,
                    context:
                        "A stale iPhone microphone teardown requires a new session"
                )
            }
            deferredAudioRecoveryRequiresReconnect(after: token)
            return .recoveryFailed
        }
        // A default interruption intentionally advances the lifecycle epoch while an executing C
        // is retained. Once that exact C drains, only the current interruption state may decide
        // whether it is still eligible to install its hosted-call successor.
        authorizeHostedCallPolicyIfEligible(
            admissiblePredecessorOperationID: token.operationID
        )
        publishSnapshot()
        return .noDeferredRecovery
    }

    private func ownsExactEstablishedMicrophoneTopology(
        _ authorization: WebRTCIOSMicrophoneAuthorization?
    ) -> Bool {
        guard let authorization else {
            return false
        }
        if let transition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition,
           transition.purpose == .topology,
           transition.category
                == AVAudioSession.Category.playAndRecord.rawValue,
           transition.generation == microphoneTopologyGeneration,
           microphoneTopologyIsEnabled,
           transition.microphoneAuthorization === authorization,
           authorization.isValid,
           nativeOperationIsCurrent(transition) {
            return true
        }
        guard let establishedMicrophoneTopologyIdentity else {
            return false
        }
        return establishedMicrophoneTopologyIdentity.authorization
                === authorization
            && establishedMicrophoneTopologyIdentity.generation
                == microphoneTopologyGeneration
            && microphoneTopologyIsEnabled
            && authorization.isValid
    }

    private func updateEstablishedMicrophoneTopologyIdentityAfterRetiring(
        _ transition: ExpectedAudioCategoryTransition,
        preservesAuthorization: Bool
    ) {
        if preservesAuthorization,
           let authorization = transition.microphoneAuthorization {
            establishedMicrophoneTopologyIdentity =
                EstablishedMicrophoneTopologyIdentity(
                    authorization: authorization,
                    generation: transition.generation,
                    operationID: transition.operationID
                )
            return
        }
        if establishedMicrophoneTopologyIdentity?.authorization
            === transition.microphoneAuthorization {
            establishedMicrophoneTopologyIdentity = nil
        }
    }

    private func clearValidatedDeferredRecoveryDispositionAfterRetiring(
        _ transition: ExpectedAudioCategoryTransition
    ) {
        guard transition.purpose == .outputOnlyMicrophone,
              pendingDeferredRecovery?.operationID
                == transition.operationID,
              deferredOutputOnlyRecoveryDisposition
                == .retryableAfterValidatedNativeSuccess(
                    operationID: transition.operationID
                ) else {
            return
        }
        // C has now crossed its ordered drain boundary. Preserve the recovery intent and boundary,
        // but release the terminal-C retry gate so the next eligible recovery can stage B.
        deferredOutputOnlyRecoveryDisposition = nil
    }

    private var currentAudioCategoryTransitionOperationID: UUID? {
        (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?.operationID
    }

    @discardableResult
    private func retireExpectedAudioCategoryTransitionForBoundary() -> Bool {
        let transition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        let retired = cancelExpectedAudioCategoryTransition(
            terminalCleanup: true
        )
        guard !retired,
              let transition,
              (expectedAudioCategoryTransition.map {
                audioCategoryTransition($0, exactlyMatches: transition)
              } == true
                || completedAudioCategoryTransition.map {
                    audioCategoryTransition($0, exactlyMatches: transition)
                } == true) else {
            return retired
        }
        // A hard lifecycle boundary may arrive before the reducer's ordered drain is accepted.
        // Retain the exact marker/tag so a later retry can redrive that drain, but revoke every
        // native capability now so stale A/B proof cannot reopen gates across the boundary.
        transition.microphoneAuthorization?.revoke()
        transition.recoveryAuthorization?.revoke()
        transition.outputOnlyToken?.revoke()
        _ = advanceAudioOperationEpoch()
        return false
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
              audioPolicyOperationCanProceedDuringPlaybackPause(
                operation
              ),
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
            && lhs.transactionOperation == rhs.transactionOperation
            && lhs.transactionProof == rhs.transactionProof
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
        establishedMicrophoneTopologyIdentity?.authorization.revoke()
        establishedMicrophoneTopologyIdentity = nil
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
              currentAudioPolicyOperationCanProceedDuringPlaybackPause,
              !mediaServicesAreLost,
              playback.requiresRuntimePlayoutProof else { return }

        if expectedAudioCategoryTransition?.purpose == .recovery,
           expectedAudioCategoryTransition?
            .recoveryAuthorization != nil {
            // A transaction-owned recovery accepts only its exact proof receipt. Ordinary or
            // delayed proof callbacks are observational and cannot complete, fail, or retire it.
            return
        }

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
        let deferredRecoveryOperationID: UUID?
        if let transition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition,
           transition.purpose == .recovery,
           pendingDeferredRecovery?.operationID
                == transition.operationID {
            deferredRecoveryOperationID = transition.operationID
        } else {
            deferredRecoveryOperationID = nil
        }
        let playbackPauseRecoveryOperationID: UUID?
        if let transition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition,
           transition.purpose == .recovery,
           case let .recovering(_, operationID) =
                microphonePlaybackPauseResumeState,
           operationID == transition.operationID {
            playbackPauseRecoveryOperationID = transition.operationID
        } else {
            playbackPauseRecoveryOperationID = nil
        }
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
            let establishedMicrophoneAuthorization =
                isReady && failureMessage == nil
                    ? (expectedAudioCategoryTransition
                        ?? completedAudioCategoryTransition)?
                        .microphoneAuthorization
                    : nil
            let retiredProofTransition =
                cancelExpectedAudioCategoryTransition(
                terminalCleanup: true,
                preservingEstablishedMicrophoneAuthorization:
                    establishedMicrophoneAuthorization,
                preservingMicrophonePlaybackPauseRecovery:
                    playbackPauseRecoveryOperationID != nil
                        && isReady
                        && failureMessage == nil
            )
            guard retiredProofTransition else {
                if let playbackPauseRecoveryOperationID {
                    failMicrophonePlaybackPauseRecovery(
                        operationID: playbackPauseRecoveryOperationID
                    )
                }
                establishedMicrophoneAuthorization?.revoke()
                closePlaybackGatesAndInvalidateProof()
                playbackDiagnosticText =
                    "The proven audio policy could not retire its exact transaction."
                publishSnapshot()
                return
            }
            if let playbackPauseRecoveryOperationID {
                if isReady, failureMessage == nil {
                    allowMicrophonePlaybackPauseRecovery(
                        operationID: playbackPauseRecoveryOperationID
                    )
                } else {
                    failMicrophonePlaybackPauseRecovery(
                        operationID: playbackPauseRecoveryOperationID
                    )
                }
            }
            if isReady,
               failureMessage == nil,
               pendingDeferredRecovery?.operationID
                    == deferredRecoveryOperationID {
                pendingDeferredRecovery = nil
                deferredOutputOnlyRecoveryDisposition = nil
            }
        }
        publishSnapshot()
        if isPlaying {
            backgroundPlayback.endTransitionTask()
        }
    }

    /// Consumes the immutable native category receipt stream. A category notification is optional
    /// evidence and never opens either media gate by itself.
    func consumeIOSAudioCategoryObservation(
        _ receipt: WebRTCIOSAudioCategoryObservationReceipt
    ) {
        guard isPrepared else { return }
        handleAudioTransactionDecision(
            audioTransactionAuthority.observe(receipt),
            context: "native category observation"
        )
    }

    /// Exact ordered drain evidence is the only authority that may collect one retained operation.
    func consumeIOSAudioCategoryDrain(
        _ receipt: WebRTCIOSAudioCategoryDrainReceipt
    ) {
        handleAudioTransactionDecision(
            audioTransactionAuthority.collectRetired(receipt),
            context: "native audio transaction drain"
        )
    }

    /// Consumes the terminal namespace barrier even after `stop()` made the session unprepared.
    /// A replacement device cannot bind until this exact receipt has reset the old reducer state.
    @discardableResult
    func consumeIOSAudioTransactionDeviceTeardown(
        _ receipt: WebRTCIOSAudioCategoryDeviceTeardownReceipt
    ) -> Bool {
        guard let snapshot = audioTransactionAuthority.snapshot else {
            return false
        }
        let decision = audioTransactionAuthority.retireDevice(
            receipt,
            expectedReducerRevision: snapshot.reducerRevision
        )
        if case let .ignored(reason, _, _) = decision,
           reason == .staleDeviceGeneration {
            return true
        }
        guard case let .deviceRetired(
            retiredSnapshot,
            formerCurrent
        ) = decision,
              retiredSnapshot.currentOperation == nil,
              retiredSnapshot.deviceInstanceGeneration == 0,
              retiredSnapshot.observationRegistrationGeneration == 0,
              retiredSnapshot.tombstoneCount == 0 else {
            recordAudioTransactionFailure(
                decision,
                context: "retire native audio device"
            )
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            revokeMicrophonePlaybackPauseResume()
            publishSnapshot()
            return false
        }

        let transactionTransitions = [
            expectedAudioCategoryTransition,
            completedAudioCategoryTransition,
        ].compactMap { $0 }.filter {
            $0.transactionOperation != nil
        }
        for transition in transactionTransitions {
            failMicrophonePlaybackPauseRecovery(
                operationID: transition.operationID
            )
            transition.microphoneAuthorization?.revoke()
            transition.recoveryAuthorization?.revoke()
            transition.outputOnlyToken?.revoke()
            events.cancelCategoryChangeOperation(
                transition.operationID
            )
        }
        if !transactionTransitions.isEmpty || formerCurrent != nil {
            if expectedAudioCategoryTransition?
                .transactionOperation != nil {
                expectedAudioCategoryTransition = nil
            }
            if completedAudioCategoryTransition?
                .transactionOperation != nil {
                completedAudioCategoryTransition = nil
            }
            pendingAmbiguousCategoryProof = nil
            _ = advanceAudioOperationEpoch()
        }
        // Retiring the bound native device invalidates readiness even when its final transaction
        // had already completed. In particular, a prior input-only allowance cannot survive into
        // an unbound device namespace.
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        revokeMicrophonePlaybackPauseResume()
        establishedMicrophoneTopologyIdentity?.authorization.revoke()
        establishedMicrophoneTopologyIdentity = nil
        microphoneTopologyIsEnabled = false
        _ = advanceMicrophoneTopologyGeneration()
        audioTransactionDeviceBinding = nil
        pendingAudioTransactionBoundary = nil
        pendingDeferredRecovery = nil
        deferredRecoveryAdmissionFence = nil
        deferredOutputOnlyRecoveryDisposition = nil
        retiredAudioTransactionOperations.removeAll(
            keepingCapacity: false
        )
        publishSnapshot()
        return true
    }

    /// Consumes the exact native terminal recovery receipt. Tuple history and the currently
    /// visible operation are never used to re-infer its application identity.
    func consumeIOSPlayoutRecoveryReceipt(
        _ receipt: WebRTCIOSPlayoutRecoveryReceipt
    ) {
        guard isPrepared else { return }
        handleAudioTransactionDecision(
            audioTransactionAuthority.acknowledgeNative(receipt),
            context: "native recovery acknowledgement"
        )
    }

    func updateTransactionalRuntimePlayout(
        transaction: WorldwideAudioRecoveryTransaction,
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil
    ) {
        guard isPrepared,
              let transition = expectedAudioCategoryTransition,
              transition.purpose == .recovery,
              transition.transactionOperation == transaction.operation,
              transition.transactionProof == transaction.proof,
              transition.recoveryAuthorization ===
                transaction.authorization else {
            return
        }
        if let failureMessage {
            playbackErrorText = failureMessage
            playbackDiagnosticText = diagnostic
        }
        let decision = audioTransactionAuthority.resolveProof(
            transaction.proof,
            succeeded: isReady && failureMessage == nil
        )
        handleAudioTransactionDecision(
            decision,
            context: "runtime playout proof"
        )
    }

    private func handleAudioTransactionDecision(
        _ decision: AudioTransactionDecision,
        context: String
    ) {
        switch decision {
        case .completed(let operation):
            completeAudioTransactionIfCurrent(operation)
        case .failedClosed(let operation):
            failAudioTransactionIfCurrent(
                operation,
                context: context
            )
        case .garbageCollected(_, let operation):
            retiredAudioTransactionOperations.remove(operation)
            // A drain advances the reducer revision. Any cached successor boundary was minted
            // against the preceding revision and must never be presented to armSuccessor again.
            pendingAudioTransactionBoundary = nil
        case .rejected, .runtimeFailure:
            recordAudioTransactionFailure(
                decision,
                context: context
            )
            failAudioTransactionIfCurrent(
                audioTransactionAuthority.snapshot?
                    .currentOperation,
                context: context
            )
        case .armed, .boundaryApplied, .nativeAcknowledged,
             .observationAccepted,
             .abortedUnpublished,
             .waitingForNativeAcknowledgement, .ignored,
             .deviceBound, .deviceRetired:
            break
        }
    }

    private func completeAudioTransactionIfCurrent(
        _ operation: AudioTransactionOperationReceipt
    ) {
        guard let transition = expectedAudioCategoryTransition,
              transition.purpose == .recovery,
              transition.transactionOperation == operation else {
            return
        }
        let operationCanStillProceed =
            nativeOperationIsCurrent(transition)
        guard operationCanStillProceed else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            revokeMicrophonePlaybackPauseResume()
            publishSnapshot()
            return
        }
        guard retireAudioTransactionIfCurrent(transition) else {
            failMicrophonePlaybackPauseRecovery(
                operationID: transition.operationID
            )
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackDiagnosticText = requiresExplicitResume
                ? "The completed audio recovery could not retire its exact native transaction. Tap Resume iPhone Microphone to retry."
                : "The completed audio recovery could not retire its exact native transaction. Tap Retry Audio."
            publishSnapshot()
            return
        }
        transition.recoveryAuthorization?.revoke()
        events.cancelCategoryChangeOperation(transition.operationID)
        expectedAudioCategoryTransition = nil
        completedAudioCategoryTransition = nil
        pendingAmbiguousCategoryProof = nil
        _ = advanceAudioOperationEpoch()
        allowMicrophonePlaybackPauseRecovery(
            operationID: transition.operationID
        )
        playbackIsReady = true
        runtimePlayoutIsReady = true
        playbackErrorText = nil
        playbackDiagnosticText = nil
        if pendingDeferredRecovery?.operationID
            == transition.operationID {
            pendingDeferredRecovery = nil
            deferredOutputOnlyRecoveryDisposition = nil
        }
        publishSnapshot()
        if isPlaying {
            backgroundPlayback.endTransitionTask()
        }
    }

    private func failAudioTransactionIfCurrent(
        _ operation: AudioTransactionOperationReceipt?,
        context: String
    ) {
        guard let transition = expectedAudioCategoryTransition,
              operation == nil
                || transition.transactionOperation == operation else {
            return
        }
        guard transition.outputOnlyToken?.state != .executing else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            revokeMicrophonePlaybackPauseResume()
            playbackErrorText =
                "The iPhone audio policy failed while native microphone teardown was still executing."
            playbackDiagnosticText =
                "Audio transaction failed closed during \(context)."
            publishSnapshot()
            return
        }
        guard retireAudioTransactionIfCurrent(transition) else {
            transition.microphoneAuthorization?.revoke()
            transition.recoveryAuthorization?.revoke()
            transition.outputOnlyToken?.revoke()
            _ = advanceAudioOperationEpoch()
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            revokeMicrophonePlaybackPauseResume()
            if transition.purpose == .outputOnlyMicrophone,
               pendingDeferredRecovery?.operationID
                == transition.operationID,
               let outputOnlyToken = transition.outputOnlyToken {
                deferredAudioRecoveryRequiresReconnect(
                    after: outputOnlyToken
                )
                return
            }
            publishSnapshot()
            return
        }
        let failedPendingOutputOnlyToken =
            transition.purpose == .outputOnlyMicrophone
                && pendingDeferredRecovery?.operationID
                    == transition.operationID
                    ? transition.outputOnlyToken
                    : nil
        transition.recoveryAuthorization?.revoke()
        transition.outputOnlyToken?.revoke()
        if transition.purpose == .hostedCall {
            hostedCallPolicy?.authorization.revoke()
            hostedCallPolicy = nil
        }
        events.cancelCategoryChangeOperation(transition.operationID)
        expectedAudioCategoryTransition = nil
        completedAudioCategoryTransition = nil
        pendingAmbiguousCategoryProof = nil
        _ = advanceAudioOperationEpoch()
        failMicrophonePlaybackPauseRecovery(
            operationID: transition.operationID
        )
        revokeMicrophonePlaybackPauseResume()
        microphoneTopologyIsEnabled = false
        _ = advanceMicrophoneTopologyGeneration()
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        if let failedPendingOutputOnlyToken {
            deferredAudioRecoveryRequiresReconnect(
                after: failedPendingOutputOnlyToken
            )
            return
        }
        playbackErrorText =
            "The iPhone audio recovery could not be verified. Tap Retry Audio."
        if playbackDiagnosticText == nil {
            playbackDiagnosticText =
                "Audio transaction failed closed during \(context)."
        }
        publishSnapshot()
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
        if snapshot.hasNonEndedCall {
            revokeMicrophonePlaybackPauseResume()
        }
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
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            let canRecoverAutomatically =
                !requiresExplicitResume && !mediaServicesAreLost
            let recoveryContext =
                "Audio recovery after connected call ended failed"
            closePlaybackGatesAndInvalidateProof(
                deferredRecoveryContext:
                    canRecoverAutomatically ? recoveryContext : nil
            )
            guard canRecoverAutomatically else {
                publishSnapshot()
                return
            }
            recoverPlayback(
                context: recoveryContext,
                proofAlreadyInvalidated: true
            )
            return
        }

        if startupPolicyLost, !isInterrupted {
            waitsForConnectedCallToEndBeforeRecovery = false
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            let canRecoverAutomatically =
                !requiresExplicitResume && !mediaServicesAreLost
            let recoveryContext =
                "Audio recovery after connected-call startup ended failed"
            closePlaybackGatesAndInvalidateProof(
                deferredRecoveryContext:
                    canRecoverAutomatically ? recoveryContext : nil
            )
            guard canRecoverAutomatically else {
                publishSnapshot()
                return
            }
            recoverPlayback(
                context: recoveryContext,
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
        revokeMicrophonePlaybackPauseResume()
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
        // Retire the predecessor before proof invalidation calls into the VM. That callback may
        // synchronously arm C; the interruption boundary must preserve that new teardown so its
        // terminal completion can authorize the exact hosted policy.
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        closePlaybackGatesAndInvalidateProof(
            preservingInitializedWebRTCAudioDevice: reason == .default
        )
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
                revokeMicrophonePlaybackPauseResume()
            }
            publishSnapshot()
            return
        }

        waitsForConnectedCallToEndBeforeRecovery = false
        guard shouldResume else {
            requiresExplicitResume = true
            revokeMicrophonePlaybackPauseResume()
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
        if requiresExplicitResume {
            revokeMicrophonePlaybackPauseResume()
        }
        // Retire the pre-route operation before publishing proof invalidation. That callback may
        // synchronously arm the output-only microphone teardown; the route boundary must not then
        // revoke that newly created token or advance beyond its topology generation.
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        let canRecoverAutomatically =
            !isInterrupted
                && !requiresExplicitResume
                && !waitsForConnectedCallToEndBeforeRecovery
                && !mediaServicesAreLost
        closePlaybackGatesAndInvalidateProof(
            deferredRecoveryContext:
                canRecoverAutomatically
                    ? "Audio route recovery failed"
                    : nil
        )
        publishSnapshot()

        guard canRecoverAutomatically else {
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
        if requiresExplicitResume {
            revokeMicrophonePlaybackPauseResume()
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            closePlaybackGatesAndInvalidateProof()
            publishSnapshot()
            return
        }
        if isInterrupted || failedStartupPolicy {
            retireExpectedAudioCategoryTransitionForBoundary()
            _ = advanceMicrophoneTopologyGeneration()
            closePlaybackGatesAndInvalidateProof()
            publishSnapshot()
            return
        }
        // Engine reconfiguration is a native topology boundary even when the reducer-owned
        // microphone A has already retired into the established identity. Revoke that authority
        // before proof invalidation can synchronously arm its output-only successor C.
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        let canRecoverAutomatically =
            !waitsForConnectedCallToEndBeforeRecovery
                && !mediaServicesAreLost
        closePlaybackGatesAndInvalidateProof(
            deferredRecoveryContext:
                canRecoverAutomatically ? context : nil
        )
        publishSnapshot()

        guard canRecoverAutomatically else { return }
        recoverPlayback(
            context: context,
            proofAlreadyInvalidated: true
        )
    }

    private func mediaServicesWereLost() {
        guard isPrepared else { return }
        revokeMicrophonePlaybackPauseResume()
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
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        closePlaybackGatesAndInvalidateProof()
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
        // Reset is a fresh native boundary. Retire its predecessor before proof invalidation can
        // synchronously arm a new output-only microphone teardown for the reset namespace.
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        let canRecoverAutomatically =
            !isInterrupted
                && !requiresExplicitResume
                && !waitsForConnectedCallToEndBeforeRecovery
        closePlaybackGatesAndInvalidateProof(
            deferredRecoveryContext:
                canRecoverAutomatically
                    ? "Audio services recovery failed"
                    : nil
        )
        publishSnapshot()

        guard canRecoverAutomatically else {
            return
        }
        recoverPlayback(
            context: "Audio services recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    private func categoryChanged(_ change: AudioSessionCategoryChange) {
        guard isPrepared else { return }

        if rawCategoryChangeBelongsToReducerOperation(change) {
            // AudioSessionManager's inferred counter is independent from the native transaction
            // stream. Exact current/retired identity makes this callback diagnostics-only; it
            // cannot complete or tear down A/C/B in either raw-first or native-first ordering.
            playbackDiagnosticText =
                "Observed raw AVAudioSession category=\(change.category), mode=\(change.mode), options=\(change.categoryOptionsRawValue) for an exact reducer-owned operation."
            publishSnapshot()
            return
        }

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

    private func rawCategoryChangeBelongsToReducerOperation(
        _ change: AudioSessionCategoryChange
    ) -> Bool {
        let currentOperation =
            (expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition)?
                .transactionOperation
        var sawIdentity = false

        if let operationID = change.operationID {
            sawIdentity = true
            guard currentOperation?.operationID == operationID
                    || retiredAudioTransactionOperations.contains(where: {
                        $0.operationID == operationID
                    }) else {
                return false
            }
        }
        if let predecessorID = change.ambiguousPredecessorOperationID {
            sawIdentity = true
            guard retiredAudioTransactionOperations.contains(where: {
                $0.operationID == predecessorID
            }) else {
                return false
            }
        }
        if let blockerID = change.blockingTombstoneOperationID {
            sawIdentity = true
            guard retiredAudioTransactionOperations.contains(where: {
                $0.operationID == blockerID
            }) else {
                return false
            }
        }
        return sawIdentity
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
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        closePlaybackGatesAndInvalidateProof()
        publishSnapshot()
    }

    @discardableResult
    private func recoverPlayback(
        context: String,
        proofAlreadyInvalidated: Bool = false,
        successorBoundary: AudioTransactionBoundaryReceipt? = nil,
        preservingEstablishedMicrophoneAuthorization:
            WebRTCIOSMicrophoneAuthorization? = nil,
        explicitMicrophoneResumeBoundaryID: UUID? = nil,
        coalesceCurrentLiveRecovery: Bool = false
    ) -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        let microphoneResumeBoundaryIsCurrent: Bool
        if let explicitMicrophoneResumeBoundaryID {
            if requiresExplicitResume,
               case let .recovering(boundaryID, operationID) =
                    microphonePlaybackPauseResumeState,
               boundaryID == explicitMicrophoneResumeBoundaryID,
               operationID == nil {
                microphoneResumeBoundaryIsCurrent = true
            } else {
                microphoneResumeBoundaryIsCurrent = false
            }
        } else {
            microphoneResumeBoundaryIsCurrent = !requiresExplicitResume
        }
        guard !isInterrupted,
              hostedCallPolicy == nil,
              microphoneResumeBoundaryIsCurrent,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return false
        }
        let transactionStagingRequest =
            onPlayoutRecoveryTransactionStagingRequested
        let transactionProofRequest =
            onTransactionalPlaybackRecoveryRequested
        guard (transactionStagingRequest == nil)
                == (transactionProofRequest == nil) else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackDiagnosticText =
                "The audio transaction recovery callbacks were only partially installed."
            publishSnapshot()
            return false
        }
        let usesTransactionalRecovery =
            transactionStagingRequest != nil
        guard !usesTransactionalRecovery
                || audioTransactionDeviceBinding != nil else {
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackDiagnosticText =
                "No exact native audio-device transaction authority was bound."
            publishSnapshot()
            return false
        }

        if coalesceCurrentLiveRecovery,
           let recoveryTransition = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition,
           recoveryTransition.purpose == .recovery,
           nativeOperationIsCurrent(recoveryTransition),
           audioPolicyOperationCanProceedDuringPlaybackPause(
               recoveryTransition
           ),
           recoveryTransition.transactionOperation == nil
                || (recoveryTransition.transactionOperation.map {
                        !retiredAudioTransactionOperations.contains($0)
                    } == true
                    && (recoveryTransition.recoveryAuthorization?.isValid
                            == true
                        || (recoveryTransition.recoveryAuthorization?
                                .hasAcceptedTerminalOutcome == true
                            && recoveryTransition.recoveryAuthorization?
                                .terminalReceipt?
                                .policyMatchesRequestedTarget == true))) {
            // Resume/Retry may be tapped again while exact B is awaiting native acknowledgement or
            // runtime proof. The live operation already represents the new user intent; preserve
            // its authorization and proof instead of retiring it and staging a second B.
            publishSnapshot()
            return true
        }

        let preservesExactEstablishedMicrophone =
            ownsExactEstablishedMicrophoneTopology(
                preservingEstablishedMicrophoneAuthorization
            )
        if !proofAlreadyInvalidated {
            invalidateAudioProofForLifecycle(
                requiresFreshRecovery: false,
                deferredRecoveryContext:
                    preservesExactEstablishedMicrophone
                        ? nil
                        : context
            )
        }
        guard deferredRecoveryAdmissionFence == nil else {
            publishSnapshot()
            return false
        }
        if let transition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition,
           transition.purpose == .outputOnlyMicrophone,
           let token = transition.outputOnlyToken {
            let explicitMicrophoneResumeCanRetryValidatedC: Bool
            if let explicitMicrophoneResumeBoundaryID,
               requiresExplicitResume,
               case let .recovering(boundaryID, operationID) =
                microphonePlaybackPauseResumeState,
               boundaryID == explicitMicrophoneResumeBoundaryID,
               operationID == nil,
               pendingDeferredRecovery?.operationID
                == token.operationID,
               deferredOutputOnlyRecoveryDisposition
                == .retryableAfterValidatedNativeSuccess(
                    operationID: token.operationID
                ) {
                explicitMicrophoneResumeCanRetryValidatedC = true
            } else {
                explicitMicrophoneResumeCanRetryValidatedC = false
            }
            guard token.operationID == transition.operationID,
                  token.lifecycleGeneration == transition.generation,
                  explicitMicrophoneResumeBoundaryID == nil
                    || explicitMicrophoneResumeCanRetryValidatedC else {
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                  publishSnapshot()
                  return false
            }
            if pendingDeferredRecovery?.operationID
                != token.operationID {
                pendingDeferredRecovery = PendingDeferredRecovery(
                    operationID: token.operationID,
                    requiresRemoteAudio: false,
                    context:
                        pendingPostCallMicrophoneRecoveryMilestone
                            == nil
                                ? context
                                : "Audio recovery after microphone teardown and call end failed"
                )
            }
            if deferredOutputOnlyRecoveryDisposition?.operationID
                != token.operationID {
                deferredOutputOnlyRecoveryDisposition =
                    .awaitingVMValidation(
                        operationID: token.operationID
                    )
            }
            switch token.state {
            case .armed, .executing:
                // The VM owns the asynchronous native C. B may be staged only after C returns
                // successfully and that task proves current peer/session/teardown ownership.
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                publishSnapshot()
                return true
            case .succeeded:
                // A terminal C can remain current when its first ordered drain request was
                // refused. Token success alone is insufficient: the owning async VM task must
                // first validate current peer/session ownership and the enclosing native result.
                guard deferredOutputOnlyRecoveryDisposition
                        == .retryableAfterValidatedNativeSuccess(
                            operationID: token.operationID
                        ) else {
                    playbackIsReady = false
                    runtimePlayoutIsReady = false
                    remoteAudioControl?.setEnabled(false)
                    publishSnapshot()
                    return deferredOutputOnlyRecoveryDisposition
                        == .awaitingVMValidation(
                            operationID: token.operationID
                        )
                }
                let deferredRecovery = pendingDeferredRecovery
                let retiringTransaction = transition.transactionOperation
                guard cancelExpectedAudioCategoryTransition(
                    operationID: transition.operationID,
                    purpose: .outputOnlyMicrophone,
                    terminalCleanup: true
                ) else {
                    playbackIsReady = false
                    runtimePlayoutIsReady = false
                    remoteAudioControl?.setEnabled(false)
                    playbackErrorText = pendingPostCallMicrophoneRecoveryMilestone
                        == nil
                            ? "Screen and control are still available. Tap Retry Audio to restore iPhone audio."
                            : "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
                    publishSnapshot()
                    return false
                }
                guard let deferredRecovery else {
                    playbackIsReady = false
                    runtimePlayoutIsReady = false
                    remoteAudioControl?.setEnabled(false)
                    playbackDiagnosticText =
                        "The terminal microphone teardown lost its deferred recovery ownership."
                    publishSnapshot()
                    return false
                }
                pendingDeferredRecovery = deferredRecovery
                deferredOutputOnlyRecoveryDisposition = nil
                let recoveryBoundary: AudioTransactionBoundaryReceipt?
                if let boundary = pendingAudioTransactionBoundary,
                   boundary.blocker == retiringTransaction {
                    recoveryBoundary = boundary
                } else {
                    recoveryBoundary = nil
                }
                _ = advanceMicrophoneTopologyGeneration()
                return recoverPlayback(
                    context: deferredRecovery.context,
                    proofAlreadyInvalidated: true,
                    successorBoundary: recoveryBoundary,
                    explicitMicrophoneResumeBoundaryID:
                        explicitMicrophoneResumeBoundaryID
                )
            case .failed, .revoked:
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                if pendingPostCallMicrophoneRecoveryMilestone != nil {
                    playbackErrorText =
                        "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
                    playbackDiagnosticText =
                        "The post-call microphone teardown did not complete successfully."
                }
                publishSnapshot()
                return false
            }
        }
        if let disposition = deferredOutputOnlyRecoveryDisposition {
            // C may already have retired into a one-shot receipt while the VM still awaits its
            // enclosing native result. Only receipt consumption may clear this zero-transition
            // handoff and stage B.
            publishSnapshot()
            if case .awaitingVMValidation = disposition {
                return true
            }
            return false
        }
        let recoveryCategory = microphoneTopologyIsEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue
        let recoveryMode = AVAudioSession.Mode.default.rawValue
        let recoveryOptions = Self.ordinaryCategoryOptionsRawValue(
            microphoneIsEnabled: microphoneTopologyIsEnabled
        )
        let recoveryOperationID: UUID?
        if let successorBoundary {
            let operationID = UUID()
            recoveryOperationID = installExpectedAudioCategoryTransition(
                operationID: operationID,
                category: recoveryCategory,
                mode: recoveryMode,
                categoryOptionsRawValue: recoveryOptions,
                purpose: .recovery,
                outputOnlyToken: nil,
                admissiblePredecessorOperationID:
                    successorBoundary.blocker?.operationID,
                successorBoundary: successorBoundary
            )
        } else {
            recoveryOperationID = armExpectedAudioCategoryTransition(
                category: recoveryCategory,
                mode: recoveryMode,
                categoryOptionsRawValue: recoveryOptions,
                purpose: .recovery,
                preservingEstablishedMicrophoneAuthorization:
                    preservingEstablishedMicrophoneAuthorization
            )
        }
        guard let recoveryOperationID else {
            publishSnapshot()
            return false
        }
        if recoveryCategory
            == AVAudioSession.Category.playback.rawValue {
            let deferredRecovery = pendingDeferredRecovery
            pendingDeferredRecovery = PendingDeferredRecovery(
                operationID: recoveryOperationID,
                requiresRemoteAudio:
                    deferredRecovery?.requiresRemoteAudio ?? false,
                context: deferredRecovery?.context ?? context
            )
            deferredOutputOnlyRecoveryDisposition = nil
        }
        if let explicitMicrophoneResumeBoundaryID {
            guard case let .recovering(boundaryID, operationID) =
                    microphonePlaybackPauseResumeState,
                  boundaryID == explicitMicrophoneResumeBoundaryID,
                  operationID == nil else {
                _ = cancelExpectedAudioCategoryTransition(
                    operationID: recoveryOperationID,
                    purpose: .recovery,
                    terminalCleanup: true
                )
                publishSnapshot()
                return false
            }
            microphonePlaybackPauseResumeState = .recovering(
                boundaryID: boundaryID,
                operationID: recoveryOperationID
            )
        }
        guard let recoveryTransition =
                expectedAudioCategoryTransition,
              recoveryTransition.operationID
                == recoveryOperationID else {
            failMicrophonePlaybackPauseRecovery(
                operationID: recoveryOperationID
            )
            failClosedAfterStaleNativeOperation()
            publishSnapshot()
            return false
        }
        let recoveryTransactionOperation =
            recoveryTransition.transactionOperation
        let recoveryTransactionProof =
            recoveryTransition.transactionProof
        guard !usesTransactionalRecovery
                || (recoveryTransactionOperation != nil
                    && recoveryTransactionProof != nil) else {
            failMicrophonePlaybackPauseRecovery(
                operationID: recoveryOperationID
            )
            failClosedAfterStaleNativeOperation()
            publishSnapshot()
            return false
        }
        var recoveryAuthorization:
            WebRTCIOSPlayoutRecoveryAuthorization?
        if usesTransactionalRecovery {
            guard let stage = transactionStagingRequest,
                  let recoveryTransactionOperation,
                  let authorization = stage(
                    recoveryTransactionOperation.nativeContext,
                    recoveryCategory
                        == AVAudioSession.Category
                            .playAndRecord.rawValue
                  ),
                  authorization.transaction
                    == recoveryTransactionOperation.nativeContext,
                  let tagGeneration =
                    authorization.stagedTransactionTagGeneration else {
                _ = cancelExpectedAudioCategoryTransition(
                    operationID: recoveryOperationID,
                    purpose: .recovery,
                    terminalCleanup: true
                )
                failMicrophonePlaybackPauseRecovery(
                    operationID: recoveryOperationID
                )
                publishSnapshot()
                return false
            }
            recoveryAuthorization = authorization
            expectedAudioCategoryTransition?
                .recoveryAuthorization = authorization
            expectedAudioCategoryTransition?
                .transactionTagGeneration = tagGeneration
        }
        do {
            try playback.recover()
            guard consumeNativeOperationCommitIfCurrent(
                recoveryTransition
            ) else {
                if let recoveryAuthorization {
                    // A newer exact transaction owns the shared native policy now. Revoke only
                    // stale B's carrier and leave D untouched while its own boundary stays closed.
                    recoveryAuthorization.revoke()
                    playbackIsReady = false
                    runtimePlayoutIsReady = false
                    remoteAudioControl?.setEnabled(false)
                } else {
                    // The legacy path has no newer native capability to preserve; undo the stale
                    // synchronous gate opening exactly as before transaction ownership existed.
                    failClosedAfterStaleNativeOperation()
                }
                failMicrophonePlaybackPauseRecovery(
                    operationID: recoveryOperationID
                )
                publishSnapshot()
                return false
            }
            if let recoveryAuthorization,
               let recoveryTransactionOperation,
               let recoveryTransactionProof,
               let currentTransition =
                expectedAudioCategoryTransition {
                guard currentTransition.transactionOperation
                        == recoveryTransactionOperation else {
                    recoveryAuthorization.revoke()
                    playbackIsReady = false
                    runtimePlayoutIsReady = false
                    remoteAudioControl?.setEnabled(false)
                    failMicrophonePlaybackPauseRecovery(
                        operationID: recoveryOperationID
                    )
                    publishSnapshot()
                    return false
                }
                playbackIsReady = false
                runtimePlayoutIsReady = false
                transactionProofRequest?(
                    WorldwideAudioRecoveryTransaction(
                        operation:
                            recoveryTransactionOperation,
                        proof: recoveryTransactionProof,
                        authorization: recoveryAuthorization
                    )
                )
                publishSnapshot()
                return true
            }
            playbackIsReady = true
            runtimePlayoutIsReady = !playback.requiresRuntimePlayoutProof
            playbackErrorText = nil
            playbackDiagnosticText = nil
            if !playback.requiresRuntimePlayoutProof {
                let transitionWasRetired =
                    cancelExpectedAudioCategoryTransition(
                    operationID: recoveryOperationID,
                    preservingMicrophonePlaybackPauseRecovery: true
                )
                guard transitionWasRetired else {
                    failMicrophonePlaybackPauseRecovery(
                        operationID: recoveryOperationID
                    )
                    closePlaybackGatesAndInvalidateProof()
                    publishSnapshot()
                    return false
                }
                if pendingDeferredRecovery?.operationID
                    == recoveryOperationID {
                    pendingDeferredRecovery = nil
                    deferredOutputOnlyRecoveryDisposition = nil
                }
                allowMicrophonePlaybackPauseRecovery(
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
            // Retire the exact staged transaction while its native carrier is still available.
            // A failed drain request intentionally retains that carrier so a later boundary can
            // retry; successful cancellation performs the revocation only after drain admission.
            let cancellationSucceeded =
                cancelExpectedAudioCategoryTransition(
                    operationID: recoveryOperationID,
                    purpose: .recovery,
                    terminalCleanup: true
                )
            failMicrophonePlaybackPauseRecovery(
                operationID: recoveryOperationID
            )
            guard cancellationSucceeded else {
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                publishSnapshot()
                return false
            }
            if pendingDeferredRecovery?.operationID
                == recoveryOperationID {
                pendingDeferredRecovery = nil
                if deferredOutputOnlyRecoveryDisposition?.operationID
                    == recoveryOperationID {
                    deferredOutputOnlyRecoveryDisposition = nil
                }
            }
            playbackIsReady = false
            recordPlaybackFailure(context: context, error: error)
            publishSnapshot()
            return false
        }
    }

    private func closePlaybackGatesAndInvalidateProof(
        preservingInitializedWebRTCAudioDevice: Bool = false,
        deferredRecoveryContext: String? = nil,
        deferredRecoveryRequiresRemoteAudio: Bool = false
    ) {
        if requiresExplicitResume {
            revokeMicrophonePlaybackPauseResume()
        }
        runtimePlayoutIsReady = false
        playbackIsReady = false
        remoteAudioControl?.setEnabled(false)
        invalidateAudioProofForLifecycle(
            requiresFreshRecovery: true,
            deferredRecoveryContext: deferredRecoveryContext,
            deferredRecoveryRequiresRemoteAudio:
                deferredRecoveryRequiresRemoteAudio
        )
        if preservingInitializedWebRTCAudioDevice {
            playback.prepareForHostedCallInterruption()
        } else {
            playback.prepareManualAudioDisabled()
        }
    }

    /// Proof invalidation synchronously calls into the VM, which can arm output-only teardown C.
    /// Install the admission fence first and let `beginIPhoneMicrophoneOutputOnlyTransition` bind
    /// it to C atomically. If C was required but could not be armed, retain the unbound fence and
    /// fail closed instead of allowing snapshot reconciliation to recreate A.
    private func invalidateAudioProofForLifecycle(
        requiresFreshRecovery: Bool,
        deferredRecoveryContext: String?,
        deferredRecoveryRequiresRemoteAudio: Bool = false
    ) {
        let expectsOutputOnlyTeardown =
            deferredRecoveryContext != nil
                && microphoneTopologyIsEnabled
                && onAudioProofInvalidated != nil
        let fenceID: UUID?
        if expectsOutputOnlyTeardown,
           let deferredRecoveryContext {
            let fence = DeferredRecoveryAdmissionFence(
                fenceID: UUID(),
                requiresRemoteAudio:
                    deferredRecoveryRequiresRemoteAudio,
                context: deferredRecoveryContext
            )
            deferredRecoveryAdmissionFence = fence
            fenceID = fence.fenceID
        } else {
            fenceID = nil
        }

        onAudioProofInvalidated?(requiresFreshRecovery)

        guard let fenceID,
              deferredRecoveryAdmissionFence?.fenceID == fenceID else {
            return
        }
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        playbackErrorText =
            "Screen and control are still available. Reconnect this session to restore iPhone audio."
        playbackDiagnosticText =
            "The audio recovery could not arm its exact microphone teardown."
    }

    private func failClosedAfterPassiveMicrophoneHandoffFailure(
        _ authorization: WebRTCIOSMicrophoneAuthorization
    ) {
        authorization.revoke()
        playbackIsReady = false
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        playback.prepareManualAudioDisabled()
        playbackDiagnosticText =
            "The established microphone could not transfer into an exact passive audio recovery transaction."
        publishSnapshot()
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
        revokeMicrophonePlaybackPauseResume()
        retireExpectedAudioCategoryTransitionForBoundary()
        _ = advanceMicrophoneTopologyGeneration()
        closePlaybackGatesAndInvalidateProof()
    }

    private func recordPlaybackFailure(context: String, error: Error) {
        let failedStartupPolicy = ownsStartupConnectedCallPolicy
        revokeHostedCallPolicy()
        fenceFailedStartupConnectedCallPolicyUntilCallEnd(
            failedStartupPolicy
        )
        runtimePlayoutIsReady = false
        revokeMicrophonePlaybackPauseResume()
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
        let recoveryTransition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        let ownsCurrentOutputOnlyRecovery =
            recoveryTransition?.purpose == .recovery
                && recoveryTransition?.category
                    == AVAudioSession.Category.playback.rawValue
                && recoveryTransition?.mode
                    == AVAudioSession.Mode.default.rawValue
                && recoveryTransition?.categoryOptionsRawValue
                    == Self.normalCategoryOptionsRawValue
                && pendingDeferredRecovery?.operationID
                    == recoveryTransition?.operationID
                && recoveryTransition.map(nativeOperationIsCurrent)
                    == true
        let ownsExactOutputOnlyRecovery =
            ownsCurrentOutputOnlyRecovery
                && recoveryTransition?.transactionOperation != nil
                && recoveryTransition?.recoveryAuthorization?
                    .hasAcceptedTerminalOutcome == true
                && recoveryTransition?.recoveryAuthorization?
                    .terminalReceipt?
                    .policyMatchesRequestedTarget == true
        #if DEBUG
        // Controller-only tests deliberately retain one unpublished legacy recovery seam because
        // Simulator cannot prove a native transaction target. It may consume only the exact,
        // current, tagless B after the VM has accepted its installed output-only policy. Release
        // builds can reach this milestone only through the receipt-owned branch above.
        let ownsUnpublishedLegacyOutputOnlyRecovery =
            ownsCurrentOutputOnlyRecovery
                && playbackIsReady
                && recoveryTransition?.recoveryAuthorization == nil
                && recoveryTransition?.transactionTagGeneration == nil
                && onPlayoutRecoveryTransactionStagingRequested == nil
                && onTransactionalPlaybackRecoveryRequested == nil
        #else
        let ownsUnpublishedLegacyOutputOnlyRecovery = false
        #endif
        let ownsRetirableOutputOnlyRecovery =
            ownsExactOutputOnlyRecovery
                || ownsUnpublishedLegacyOutputOnlyRecovery
        guard pendingPostCallMicrophoneRecoveryMilestone
                == milestone,
              !isCallActive,
              !isInterrupted,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost,
              hostedCallPolicy == nil,
              transportIsHealthy,
              playbackIsReady || ownsExactOutputOnlyRecovery
        else {
            return false
        }
        if ownsRetirableOutputOnlyRecovery {
            guard let recoveryTransition,
                  cancelExpectedAudioCategoryTransition(
                    operationID: recoveryTransition.operationID,
                    purpose: .recovery,
                    terminalCleanup: true
                  ) else {
                playbackIsReady = false
                runtimePlayoutIsReady = false
                remoteAudioControl?.setEnabled(false)
                playbackErrorText =
                    "Screen and control are still available. Tap Retry Audio to restore iPhone audio after the call."
                playbackDiagnosticText =
                    "The post-call output-only recovery could not cross its exact ordered drain boundary."
                publishSnapshot()
                return false
            }
            if pendingDeferredRecovery?.operationID
                == recoveryTransition.operationID {
                pendingDeferredRecovery = nil
                deferredOutputOnlyRecoveryDisposition = nil
            }
            // The installed output-only policy is sufficient to reopen input admission, but it
            // is not fresh speaker-playout proof. Keep every output gate closed while the VM
            // synchronously starts the new microphone A transaction.
            playbackIsReady = false
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackErrorText = nil
            playbackDiagnosticText = nil
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
        let currentTransition = expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition
        return microphoneCallDisposition != .blocked
            && !microphoneInterruptionIsActive
            && currentTransition?.purpose != .outputOnlyMicrophone
            && pendingDeferredRecovery == nil
            && deferredRecoveryAdmissionFence == nil
            && microphoneActivationPolicyAllowsPlaybackPause
            && !mediaServicesAreLost
    }

    private var microphoneActivationPolicyAllowsPlaybackPause: Bool {
        guard requiresExplicitResume else { return true }
        guard playbackIsReady else { return false }
        if case .allowed = microphonePlaybackPauseResumeState {
            return true
        }
        return false
    }

    private func revokeMicrophonePlaybackPauseResume() {
        microphonePlaybackPauseResumeState = requiresExplicitResume
            ? .required(boundaryID: UUID())
            : .notRequired
    }

    private func allowMicrophonePlaybackPauseRecovery(
        operationID: UUID
    ) {
        guard case let .recovering(boundaryID, currentOperationID) =
                microphonePlaybackPauseResumeState,
              currentOperationID == operationID else {
            return
        }
        microphonePlaybackPauseResumeState = .allowed(
            boundaryID: boundaryID
        )
    }

    private func failMicrophonePlaybackPauseRecovery(
        operationID: UUID
    ) {
        guard case let .recovering(boundaryID, currentOperationID) =
                microphonePlaybackPauseResumeState,
              currentOperationID == operationID else {
            return
        }
        microphonePlaybackPauseResumeState = .required(
            boundaryID: boundaryID
        )
    }

    private var currentAudioPolicyOperationCanProceedDuringPlaybackPause: Bool {
        guard requiresExplicitResume else { return true }
        guard let operation = expectedAudioCategoryTransition
                ?? completedAudioCategoryTransition else {
            return false
        }
        return audioPolicyOperationCanProceedDuringPlaybackPause(
            operation
        )
    }

    private func audioPolicyOperationCanProceedDuringPlaybackPause(
        _ operation: ExpectedAudioCategoryTransition
    ) -> Bool {
        guard requiresExplicitResume else { return true }
        switch microphonePlaybackPauseResumeState {
        case .recovering(_, let operationID):
            return operation.purpose == .recovery
                && operationID == operation.operationID
        case .allowed:
            guard playbackIsReady else { return false }
            switch operation.purpose {
            case .topology:
                return operation.category
                    == AVAudioSession.Category.playAndRecord.rawValue
            case .outputOnlyMicrophone:
                return operation.category
                    == AVAudioSession.Category.playback.rawValue
            case .recovery, .callPrivacyRollback, .hostedCall:
                return false
            }
        case .notRequired, .required:
            return false
        }
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

    #if DEBUG
    var debugCurrentAudioTransactionOperationForTests:
        AudioTransactionOperationReceipt? {
        (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?
            .transactionOperation
    }

    var debugCurrentAudioTransactionPredecessorIDForTests: UUID? {
        (expectedAudioCategoryTransition
            ?? completedAudioCategoryTransition)?
            .admissiblePredecessorOperationID
    }

    var debugHasTransactionBackedCategoryTransitionForTests: Bool {
        expectedAudioCategoryTransition?
            .transactionOperation != nil
            || completedAudioCategoryTransition?
                .transactionOperation != nil
    }

    var debugRetiredAudioTransactionOperationCountForTests: Int {
        retiredAudioTransactionOperations.count
    }
    #endif
}
