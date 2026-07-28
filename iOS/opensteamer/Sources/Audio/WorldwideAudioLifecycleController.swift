import AVFoundation
import Foundation
import WebRTCTransport

struct AudioSessionCategoryChange: Equatable, Sendable {
    let category: String
    let mode: String
    let categoryOptionsRawValue: UInt
    let operationID: UUID?
    let operationIDIsAmbiguous: Bool

    init(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt = 0,
        operationID: UUID? = nil,
        operationIDIsAmbiguous: Bool = false
    ) {
        self.category = category
        self.mode = mode
        self.categoryOptionsRawValue = categoryOptionsRawValue
        self.operationID = operationID
        self.operationIDIsAmbiguous = operationIDIsAmbiguous
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
    /// CallKit is a synchronous microphone-ownership boundary only. A bare call
    /// transition does not close incoming playout gates.
    var onCallActivityChanged: ((Bool) -> Void)?
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
    private var callActivitySnapshot =
        WorldwideCallActivitySnapshot.inactive
    private var currentInterruptionEpoch: UUID?
    private var currentStartupConnectedCallScope: UUID?
    private var currentInterruptionReason:
        AudioSessionInterruptionBeganReason?
    private var hostedCallPolicy: HostedCallPolicy?
    private var hostedCallPolicyWasIssuedForCurrentInterruption = false
    private var hostedCallPolicyIsClosedForCurrentInterruption = false
    private var hostedInterruptionEndedAwaitingCallEnd = false
    private var waitsForConnectedCallToEndBeforeRecovery = false
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
    private var audioOperationEpoch: UInt64 = 0

    private static let normalCategoryOptionsRawValue: UInt = 0
    private static let hostedCallCategoryOptionsRawValue =
        AVAudioSession.CategoryOptions.mixWithOthers.rawValue

    private enum ExpectedAudioCategoryTransitionPurpose: Equatable {
        case topology
        case outputOnlyMicrophone
        case recovery
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
        callActivitySnapshot = .inactive
        currentInterruptionEpoch = nil
        currentStartupConnectedCallScope = nil
        currentInterruptionReason = nil
        hostedCallPolicy = nil
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
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

    func transportBecameHealthy() {
        guard isPrepared else { return }
        guard !transportIsHealthy else {
            publishSnapshot()
            return
        }
        transportIsHealthy = true
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
        callActivitySnapshot = .inactive
        currentInterruptionEpoch = nil
        currentStartupConnectedCallScope = nil
        currentInterruptionReason = nil
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
        requiresExplicitResume = false
        mediaServicesAreLost = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        if hadActiveCall {
            onCallActivityChanged?(false)
        }
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

    @discardableResult
    func beginMicrophoneTopologyTransition(isEnabled: Bool) -> UInt64 {
        guard isPrepared else { return 0 }
        revokeHostedCallPolicy()
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
                Self.normalCategoryOptionsRawValue,
            purpose: .topology,
            outputOnlyToken: nil
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
            outputOnlyToken: token
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

    @discardableResult
    private func armExpectedAudioCategoryTransition(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        purpose: ExpectedAudioCategoryTransitionPurpose
    ) -> UUID? {
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
            outputOnlyToken: nil
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
        hostedCallPolicyID: UUID? = nil
    ) -> UUID {
        precondition(expectedAudioCategoryTransition == nil)
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
            hostedCallPolicyID: hostedCallPolicyID
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

            if let token =
                expectedAudioCategoryTransition.outputOnlyToken {
                switch token.state {
                case .armed:
                    token.revoke()
                case .executing, .succeeded, .failed:
                    guard terminalCleanup else { return false }
                case .revoked:
                    break
                }
            }

            events.cancelCategoryChangeOperation(
                expectedAudioCategoryTransition.operationID
            )
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
        self.completedAudioCategoryTransition = nil
        _ = advanceAudioOperationEpoch()
        return true
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

    private func retireExpectedAudioCategoryTransitionForBoundary() {
        let previousOperationEpoch = audioOperationEpoch
        _ = cancelExpectedAudioCategoryTransition(
            terminalCleanup: true
        )
        if audioOperationEpoch == previousOperationEpoch {
            completedAudioCategoryTransition = nil
            _ = advanceAudioOperationEpoch()
        }
    }

    private func completeExpectedAudioCategoryTransition(
        _ transition: ExpectedAudioCategoryTransition
    ) {
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
    }

    @discardableResult
    private func advanceAudioOperationEpoch() -> UInt64 {
        audioOperationEpoch &+= 1
        if audioOperationEpoch == 0 {
            audioOperationEpoch = 1
        }
        return audioOperationEpoch
    }

    @discardableResult
    private func advanceMicrophoneTopologyGeneration() -> UInt64 {
        microphoneTopologyGeneration &+= 1
        if microphoneTopologyGeneration == 0 {
            microphoneTopologyGeneration = 1
        }
        return microphoneTopologyGeneration
    }

    /// Accepts proof from the output-only RemoteIO render-input boundary. Signaling, a decoded
    /// track, and WebRTC's global audio gate are insufficient even for that boundary, and healthy
    /// callback PCM is not evidence of the later iOS mixer/route/DAC/speaker output.
    func updateRuntimePlayout(
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil
    ) {
        guard isPrepared,
              !isInterrupted,
              hostedCallPolicy == nil,
              !requiresExplicitResume,
              !mediaServicesAreLost,
              playback.requiresRuntimePlayoutProof else { return }
        runtimePlayoutIsReady = isReady
        if let failureMessage {
            playbackIsReady = false
            playbackErrorText = failureMessage
            playbackDiagnosticText = diagnostic
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

        callActivitySnapshot = snapshot
        let startupPolicyLost: Bool
        if let policy = hostedCallPolicy,
           !hostedCallIntersectionHolds(policy) {
            startupPolicyLost =
                policy.scope.origin == .startupConnectedCall
            revokeHostedCallPolicy()
        } else {
            startupPolicyLost = false
        }

        // The microphone-facing state is always published before any recovery can reopen an audio
        // policy. A non-ended call therefore closes or keeps closed microphone ownership first.
        onCallActivityChanged?(snapshot.hasNonEndedCall)

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

        authorizeHostedCallPolicyIfEligible()
        publishSnapshot()
    }

    private func interruptionBegan(
        reason: AudioSessionInterruptionBeganReason
    ) {
        guard isPrepared else { return }
        revokeHostedCallPolicy()
        hostedCallPolicyWasIssuedForCurrentInterruption = false
        hostedCallPolicyIsClosedForCurrentInterruption = false
        hostedInterruptionEndedAwaitingCallEnd = false
        waitsForConnectedCallToEndBeforeRecovery = false
        currentInterruptionEpoch = UUID()
        currentInterruptionReason = reason
        isInterrupted = true
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
        authorizeHostedCallPolicyIfEligible()
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isPrepared else { return }
        let preservedInitializedWebRTCAudioDevice =
            currentInterruptionReason == .default
        synchronizeLiveCallStateIfNeeded()

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
        if purpose != .hostedCall {
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
            case .hostedCall:
                break
            }
        }
        publishSnapshot()
        if purpose != .hostedCall {
            authorizeHostedCallPolicyIfEligible()
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

        case .topology, .outputOnlyMicrophone, .recovery:
            let currentCategory = microphoneTopologyIsEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue
            return transition.hostedCallPolicyID == nil
                && change.category == currentCategory
                && change.mode == AVAudioSession.Mode.default.rawValue
                && change.categoryOptionsRawValue
                    == Self.normalCategoryOptionsRawValue
        }
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
        runtimePlayoutIsReady = false
        switch transition.purpose {
        case .hostedCall:
            // The policy remains pending, but neither native nor decoded-track readiness can open
            // until diagnostics prove the exact authorization.
            playbackIsReady = false
            remoteAudioControl?.setEnabled(false)
            publishSnapshot()

        case .topology, .outputOnlyMicrophone:
            guard playback.requiresRuntimePlayoutProof else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            if !isInterrupted {
                onPlayoutProofRefreshRequested?()
            }
            publishSnapshot()

        case .recovery:
            guard playback.requiresRuntimePlayoutProof else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
            // recoverPlayback() requests the exact native recovery only after its synchronously
            // executing operation passes the post-call identity fence.
            publishSnapshot()
        }
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

    private func recoverPlayback(
        context: String,
        proofAlreadyInvalidated: Bool = false
    ) {
        guard isPrepared else { return }
        synchronizeLiveCallStateIfNeeded()
        guard !isInterrupted,
              hostedCallPolicy == nil,
              !requiresExplicitResume,
              !waitsForConnectedCallToEndBeforeRecovery,
              !mediaServicesAreLost else {
            publishSnapshot()
            return
        }

        if !proofAlreadyInvalidated {
            onAudioProofInvalidated?(false)
        }
        guard let recoveryOperationID =
            armExpectedAudioCategoryTransition(
            category: microphoneTopologyIsEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.normalCategoryOptionsRawValue,
            purpose: .recovery
            ) else {
            publishSnapshot()
            return
        }
        guard let recoveryTransition =
                expectedAudioCategoryTransition,
              recoveryTransition.operationID
                == recoveryOperationID else {
            failClosedAfterStaleNativeOperation()
            publishSnapshot()
            return
        }
        do {
            try playback.recover()
            guard consumeNativeOperationCommitIfCurrent(
                recoveryTransition
            ) else {
                failClosedAfterStaleNativeOperation()
                publishSnapshot()
                return
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
        } catch {
            guard consumeNativeOperationCommitIfCurrent(
                recoveryTransition
            ) else {
                failClosedAfterStaleNativeOperation()
                publishSnapshot()
                return
            }
            cancelExpectedAudioCategoryTransition(
                operationID: recoveryOperationID
            )
            playbackIsReady = false
            recordPlaybackFailure(context: context, error: error)
            publishSnapshot()
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
        return !isCallActive
            && !isInterrupted
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

    private func authorizeHostedCallPolicyIfEligible() {
        guard
            isPrepared,
            hostedCallPolicy == nil,
            !hostedCallPolicyWasIssuedForCurrentInterruption,
            !hostedCallPolicyIsClosedForCurrentInterruption,
            expectedAudioCategoryTransition == nil,
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
            scope: .interruption(currentInterruptionEpoch)
        )
        hostedCallPolicyWasIssuedForCurrentInterruption =
            hostedCallPolicy != nil
    }

    private func issueHostedCallPolicy(scope: HostedCallScope) {
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
            hostedCallPolicyID: policyID
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
