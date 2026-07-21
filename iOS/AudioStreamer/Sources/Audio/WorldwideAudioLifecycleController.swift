import AVFoundation
import Foundation
import WebRTCTransport

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
    var onEngineConfigurationChanged: (() -> Void)? { get set }
    var onMediaServicesReset: (() -> Void)? { get set }

    func startObserving()
    func stopObserving()
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
    /// A synchronous audio-policy boundary. The view model uses it to retire proof tasks and
    /// revoke the exact native recovery authorization before this controller changes WebRTC's
    /// process-wide manual audio gate. It never tears down signaling, video, screen, or control.
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
    private var isBlockedByCall = false
    private var requiresExplicitResume = false
    private var playbackErrorText: String?
    private var playbackDiagnosticText: String?
    private var serverName = "Mac mini"
    private var remoteAudioControl: (any WorldwideRemoteAudioControlling)?

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
        isBlockedByCall = false
        requiresExplicitResume = false
        playbackErrorText = nil
        playbackDiagnosticText = nil

        // Install and synchronously sample CallKit before any path can open WebRTC's global
        // native audio gate. An already-active iPhone call must never observe a transient
        // activation or AVAudioSession reconfiguration from AudioStreamer.
        callActivity.startObserving()
        events.startObserving()
        isBlockedByCall = callActivity.liveNonEndedCallCount > 0

        if isBlockedByCall {
            runtimePlayoutIsReady = false
            playback.prepareManualAudioDisabled()
            recordActiveCallBlock()
            onCallActivityChanged?(true)
        } else {
            do {
                try playback.activate()
                playbackIsReady = true
            } catch {
                // Activation can partially configure the singleton audio session before
                // throwing. Balance it, but keep this lifecycle prepared so screen/signaling
                // can connect and a later explicit audio recovery can retry independently.
                playback.deactivate()
                recordPlaybackFailure(
                    context: "Initial background audio preparation failed",
                    error: error
                )
            }
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
        if synchronizeLiveCallBlockIfNeeded() {
            // A replacement WebRTC track can arrive already enabled while the cached call block
            // is active. Publishing synchronously applies the fail-closed per-track state; the
            // native global gate alone is not the two-gate invariant promised by the policy.
            publishSnapshot()
            return
        }
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

        let wasBlockedByCall = isBlockedByCall
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
        isBlockedByCall = false
        requiresExplicitResume = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        if wasBlockedByCall {
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

    /// Accepts proof from the output-only RemoteIO render-input boundary. Signaling, a decoded
    /// track, and WebRTC's global audio gate are insufficient even for that boundary, and healthy
    /// callback PCM is not evidence of the later iOS mixer/route/DAC/speaker output.
    func updateRuntimePlayout(
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil
    ) {
        guard isPrepared,
              !synchronizeLiveCallBlockIfNeeded(),
              !isInterrupted,
              !isBlockedByCall,
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
        publishSnapshot()
        if isPlaying {
            backgroundPlayback.endTransitionTask()
        }
    }

    // MARK: - System event handling

    private func callActivityChanged(isActive: Bool) {
        guard isPrepared, isActive != isBlockedByCall else { return }
        isBlockedByCall = isActive
        runtimePlayoutIsReady = false

        if isActive {
            // Close the decoded-track gate before allowing any asynchronous cleanup. The view
            // model callback then retires proof ownership and revokes the exact queued native
            // rebuild authorization; only afterward do we close WebRTC's process-wide gate.
            remoteAudioControl?.setEnabled(false)
            playbackIsReady = false
            onCallActivityChanged?(true)
            playback.prepareManualAudioDisabled()
            recordActiveCallBlock()
            publishSnapshot()
            return
        }

        // Rotate/fence view-model proof ownership before opening a fresh native media path.
        onCallActivityChanged?(false)
        playbackErrorText = nil
        playbackDiagnosticText = nil
        guard !isInterrupted, !requiresExplicitResume, transportIsHealthy else {
            publishSnapshot()
            return
        }
        recoverPlayback(
            context: "Post-call audio recovery failed",
            proofAlreadyInvalidated: true
        )
    }

    private func interruptionBegan() {
        guard isPrepared else { return }
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

    private func recoverPlayback(
        context: String,
        proofAlreadyInvalidated: Bool = false
    ) {
        guard isPrepared else { return }
        guard !synchronizeLiveCallBlockIfNeeded(),
              !isInterrupted,
              !isBlockedByCall,
              !requiresExplicitResume else {
            publishSnapshot()
            return
        }

        if !proofAlreadyInvalidated {
            onAudioProofInvalidated?(false)
        }
        do {
            try playback.recover()
            playbackIsReady = true
            runtimePlayoutIsReady = !playback.requiresRuntimePlayoutProof
            playbackErrorText = nil
            playbackDiagnosticText = nil
            onPlaybackRecoveryRequested?()
            publishSnapshot()
            if isPlaying {
                backgroundPlayback.endTransitionTask()
            }
        } catch {
            playbackIsReady = false
            recordPlaybackFailure(context: context, error: error)
            publishSnapshot()
        }
    }

    private func recordPlaybackFailure(context: String, error: Error) {
        playbackErrorText = "Screen and control are still available. A FaceTime or phone call, or another app, may be using iPhone audio. End it, then tap Retry Audio. Calls running on the Mac remain supported."
        playbackDiagnosticText = "\(context): \(error.localizedDescription)"
    }

    private func recordActiveCallBlock() {
        playbackErrorText = "AudioStreamer paused iPhone audio because a phone, FaceTime, or CallKit call owns the final system route. Screen and control stay connected. End the iPhone call and audio will retry automatically. Calls running on the Mac remain supported."
        playbackDiagnosticText = "CallKit reports active call ownership; the remote track and WebRTC native audio gate are closed."
    }

    /// CallKit delegate delivery is asynchronous. Re-read the privacy-minimal live aggregate at
    /// every gate-opening boundary so a queued callback cannot let recovery run first. A cached
    /// blocked state remains fail-closed until the matching final-call callback is processed.
    @discardableResult
    private func synchronizeLiveCallBlockIfNeeded() -> Bool {
        guard isPrepared else { return false }
        if callActivity.liveNonEndedCallCount > 0, !isBlockedByCall {
            callActivityChanged(isActive: true)
        }
        return isBlockedByCall
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
            && !isBlockedByCall
            && callActivity.liveNonEndedCallCount == 0
            && !requiresExplicitResume
    }

    private var stateText: String {
        guard isPrepared else { return "Inactive" }
        if isBlockedByCall { return "Audio paused — iPhone call active" }
        if isInterrupted { return "Interrupted" }
        if requiresExplicitResume { return "Paused — resume audio" }
        if !playbackIsReady { return "Playback unavailable" }
        if !hasRemoteAudio { return "Waiting for Mac audio" }
        if !transportIsHealthy { return "Reconnecting audio" }
        if !runtimePlayoutIsReady { return "Starting playback" }
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
