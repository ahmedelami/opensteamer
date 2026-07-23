import AVFoundation
import Foundation
import WebRTCTransport

struct AudioSessionCategoryChange: Equatable, Sendable {
    let category: String
    let mode: String
    let operationID: UUID?

    init(
        category: String,
        mode: String,
        operationID: UUID? = nil
    ) {
        self.category = category
        self.mode = mode
        self.operationID = operationID
    }
}

/// Abstracts the process-wide WebRTC audio device for deterministic lifecycle tests.
@MainActor
protocol WorldwideAudioPlaybackManaging: AnyObject {
    var requiresRuntimePlayoutProof: Bool { get }

    func activate() throws
    func recover() throws
    func prepareManualAudioDisabled()
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
    var onInterruptionBegan: (() -> Void)? { get set }
    var onInterruptionEnded: ((Bool) -> Void)? { get set }
    var onRouteChanged: ((String) -> Void)? { get set }
    var onCategoryChanged: ((AudioSessionCategoryChange) -> Void)? { get set }
    var onEngineConfigurationChanged: (() -> Void)? { get set }
    var onMediaServicesReset: (() -> Void)? { get set }

    func startObserving()
    func stopObserving()
    func armCategoryChangeOperation(
        _ operationID: UUID,
        category: String,
        mode: String
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
    /// retires proof ownership before an interruption closes the native audio gate, without
    /// incorrectly classifying every interruption as a phone call.
    var onAudioProofInvalidated: ((_ requiresFreshRecovery: Bool) -> Void)?

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
    private var isCallActive = false
    private var requiresExplicitResume = false
    private var playbackErrorText: String?
    private var playbackDiagnosticText: String?
    private var serverName = "Mac mini"
    private var remoteAudioControl: (any WorldwideRemoteAudioControlling)?
    private var microphoneTopologyGeneration: UInt64 = 0
    private var microphoneTopologyIsEnabled = false
    private var expectedAudioCategoryTransition:
        ExpectedAudioCategoryTransition?

    private enum ExpectedAudioCategoryTransitionPurpose: Equatable {
        case topology
        case outputOnlyMicrophone
        case recovery
    }

    private struct ExpectedAudioCategoryTransition {
        let generation: UInt64
        let operationID: UUID
        let category: String
        let mode: String
        let purpose: ExpectedAudioCategoryTransitionPurpose
        let outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken?
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

        events.onInterruptionBegan = { [weak self] in
            self?.interruptionBegan()
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
            self?.recoverPlayback(
                context: "Audio engine recovery failed"
            )
        }
        events.onMediaServicesReset = { [weak self] in
            self?.recoverPlayback(
                context: "Audio services recovery failed"
            )
        }
        callActivity.onNonEndedCallCountChanged = { [weak self] count in
            self?.callActivityChanged(isActive: count > 0)
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
        isCallActive = false
        requiresExplicitResume = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        microphoneTopologyGeneration = 0
        microphoneTopologyIsEnabled = false
        expectedAudioCategoryTransition = nil

        // Sample the privacy-minimal aggregate before microphone policy can open.
        // Playback is attempted independently and remains subject to real
        // AVAudioSession interruption and native-route failure.
        callActivity.startObserving()
        events.startObserving()
        isCallActive = callActivity.liveNonEndedCallCount > 0

        // Arm the app-owned initial playback/default transition before native activation can
        // publish its category-change notification.
        beginMicrophoneTopologyTransition(isEnabled: false)
        do {
            try playback.activate()
            playbackIsReady = true
        } catch {
            cancelExpectedAudioCategoryTransition()
            playback.deactivate()
            recordPlaybackFailure(
                context: "Initial background audio preparation failed",
                error: error
            )
        }
        if isCallActive {
            onCallActivityChanged?(true)
        }

        publishSnapshot()
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
        recoverPlayback(context: "Audio transport recovery failed")
    }

    func transportBecameUncertain() {
        guard isPrepared else { return }
        guard transportIsHealthy else {
            publishSnapshot()
            return
        }
        cancelExpectedAudioCategoryTransition()
        transportIsHealthy = false
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
        cancelExpectedAudioCategoryTransition(terminalCleanup: true)
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
        isCallActive = false
        requiresExplicitResume = false
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
        guard isPrepared else { return }
        requiresExplicitResume = false
        recoverPlayback(context: "Audio resume failed")
    }

    @discardableResult
    func beginMicrophoneTopologyTransition(isEnabled: Bool) -> UInt64 {
        guard isPrepared else { return 0 }
        guard cancelExpectedAudioCategoryTransition() else { return 0 }
        microphoneTopologyGeneration &+= 1
        if microphoneTopologyGeneration == 0 {
            microphoneTopologyGeneration = 1
        }
        microphoneTopologyIsEnabled = isEnabled
        _ = installExpectedAudioCategoryTransition(
            operationID: UUID(),
            category: isEnabled
                ? AVAudioSession.Category.playAndRecord.rawValue
                : AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            purpose: .topology,
            outputOnlyToken: nil
        )
        return microphoneTopologyGeneration
    }

    /// Arms the only lifecycle operation that may authorize a native nil microphone write.
    func beginIPhoneMicrophoneOutputOnlyTransition(
        ownerEpoch: UUID
    ) -> WebRTCIOSOutputOnlyMicrophoneToken? {
        guard isPrepared,
              cancelExpectedAudioCategoryTransition() else {
            return nil
        }

        microphoneTopologyGeneration &+= 1
        if microphoneTopologyGeneration == 0 {
            microphoneTopologyGeneration = 1
        }
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
            purpose: purpose,
            outputOnlyToken: nil
        )
    }

    @discardableResult
    private func installExpectedAudioCategoryTransition(
        operationID: UUID,
        category: String,
        mode: String,
        purpose: ExpectedAudioCategoryTransitionPurpose,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken?
    ) -> UUID {
        precondition(expectedAudioCategoryTransition == nil)
        expectedAudioCategoryTransition = ExpectedAudioCategoryTransition(
            generation: microphoneTopologyGeneration,
            operationID: operationID,
            category: category,
            mode: mode,
            purpose: purpose,
            outputOnlyToken: outputOnlyToken
        )
        events.armCategoryChangeOperation(
            operationID,
            category: category,
            mode: mode
        )
        return operationID
    }

    @discardableResult
    private func cancelExpectedAudioCategoryTransition(
        operationID: UUID? = nil,
        purpose: ExpectedAudioCategoryTransitionPurpose? = nil,
        terminalCleanup: Bool = false
    ) -> Bool {
        guard let expectedAudioCategoryTransition else { return true }
        if let operationID,
           expectedAudioCategoryTransition.operationID != operationID {
            return false
        }
        if let purpose,
           expectedAudioCategoryTransition.purpose != purpose {
            return false
        }

        if let token = expectedAudioCategoryTransition.outputOnlyToken {
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
        return true
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
              !requiresExplicitResume,
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

    // MARK: - System event handling

    private func callActivityChanged(isActive: Bool) {
        guard isPrepared, isActive != isCallActive else { return }
        isCallActive = isActive
        onCallActivityChanged?(isActive)
        publishSnapshot()
    }

    private func interruptionBegan() {
        guard isPrepared else { return }
        cancelExpectedAudioCategoryTransition()
        isInterrupted = true
        runtimePlayoutIsReady = false
        remoteAudioControl?.setEnabled(false)
        playbackIsReady = false
        onAudioProofInvalidated?(true)
        playback.prepareManualAudioDisabled()
        publishSnapshot()
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isPrepared else { return }
        isInterrupted = false
        // Fence reads from the interrupted native device before either staying closed or opening
        // a new recovery generation.
        onAudioProofInvalidated?(false)
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
        if message == "Audio route changed: device unavailable" {
            // Do not leak a loud stream to speakers when headphones disappear. The user can
            // explicitly resume after choosing the intended route.
            cancelExpectedAudioCategoryTransition()
            requiresExplicitResume = true
            runtimePlayoutIsReady = false
            remoteAudioControl?.setEnabled(false)
            playbackIsReady = false
            onAudioProofInvalidated?(true)
            playback.prepareManualAudioDisabled()
            publishSnapshot()
            return
        }
        recoverPlayback(context: "Audio route recovery failed")
    }

    private func categoryChanged(_ change: AudioSessionCategoryChange) {
        guard isPrepared else { return }
        let currentCategory = microphoneTopologyIsEnabled
            ? AVAudioSession.Category.playAndRecord.rawValue
            : AVAudioSession.Category.playback.rawValue
        let currentMode = AVAudioSession.Mode.default.rawValue

        guard change.category == currentCategory,
              change.mode == currentMode else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }

        guard let expectedAudioCategoryTransition,
              expectedAudioCategoryTransition.generation
                == microphoneTopologyGeneration,
              change.operationID
                == expectedAudioCategoryTransition.operationID,
              expectedAudioCategoryTransition.category == change.category,
              expectedAudioCategoryTransition.mode == change.mode else {
            failClosedForUnexpectedCategoryChange(change)
            return
        }

        if expectedAudioCategoryTransition.purpose
            == .outputOnlyMicrophone {
            guard let token =
                    expectedAudioCategoryTransition.outputOnlyToken,
                  token.lifecycleGeneration
                    == expectedAudioCategoryTransition.generation,
                  token.operationID
                    == expectedAudioCategoryTransition.operationID,
                  token.target.category
                    == expectedAudioCategoryTransition.category,
                  token.target.mode
                    == expectedAudioCategoryTransition.mode,
                  token.state == .executing
                    || token.state == .succeeded else {
                failClosedForUnexpectedCategoryChange(change)
                return
            }
        }

        let purpose = expectedAudioCategoryTransition.purpose
        self.expectedAudioCategoryTransition = nil
        events.cancelCategoryChangeOperation(
            expectedAudioCategoryTransition.operationID
        )
        playbackErrorText = nil
        playbackDiagnosticText = nil
        runtimePlayoutIsReady = !playback.requiresRuntimePlayoutProof
        if playback.requiresRuntimePlayoutProof {
            switch purpose {
            case .topology, .outputOnlyMicrophone:
                onPlayoutProofRefreshRequested?()
            case .recovery:
                break
            }
        }
        publishSnapshot()
    }

    private func failClosedForUnexpectedCategoryChange(
        _ change: AudioSessionCategoryChange
    ) {
        cancelExpectedAudioCategoryTransition(
            terminalCleanup: true
        )
        runtimePlayoutIsReady = false
        playbackIsReady = false
        remoteAudioControl?.setEnabled(false)
        playbackErrorText =
            "The iPhone audio route changed outside opensteamer’s authorized microphone policy."
        playbackDiagnosticText =
            "Unexpected AVAudioSession category=\(change.category), mode=\(change.mode)."
        onAudioProofInvalidated?(true)
        playback.prepareManualAudioDisabled()
        publishSnapshot()
    }

    private func recoverPlayback(
        context: String,
        proofAlreadyInvalidated: Bool = false
    ) {
        guard isPrepared else { return }
        synchronizeLiveCallStateIfNeeded()
        guard !isInterrupted, !requiresExplicitResume else {
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
            purpose: .recovery
            ) else {
            publishSnapshot()
            return
        }
        do {
            try playback.recover()
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
            cancelExpectedAudioCategoryTransition(
                operationID: recoveryOperationID
            )
            playbackIsReady = false
            recordPlaybackFailure(context: context, error: error)
            publishSnapshot()
        }
    }

    private func recordPlaybackFailure(context: String, error: Error) {
        playbackErrorText = "Screen and control are still available. iOS interrupted or rejected the current audio route. Restore the intended route, then tap Retry Audio."
        playbackDiagnosticText = "\(context): \(error.localizedDescription)"
    }

    /// Re-reads CallKit synchronously at every microphone-opening boundary.
    func microphoneActivationIsAllowed() -> Bool {
        guard isPrepared else { return false }
        synchronizeLiveCallStateIfNeeded()
        return !isCallActive
            && !isInterrupted
            && !requiresExplicitResume
    }

    private func synchronizeLiveCallStateIfNeeded() {
        guard isPrepared else { return }
        let liveState = callActivity.liveNonEndedCallCount > 0
        if liveState != isCallActive {
            callActivityChanged(isActive: liveState)
        }
    }

    // MARK: - Derived policy state

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
            && !isInterrupted
            && !requiresExplicitResume
    }

    private var stateText: String {
        guard isPrepared else { return "Inactive" }
        if isInterrupted { return "Interrupted" }
        if requiresExplicitResume { return "Paused — resume audio" }
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
}
