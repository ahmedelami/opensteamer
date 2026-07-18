import AVFoundation
import Foundation
import WebRTCTransport

@MainActor
protocol WorldwideAudioPlaybackManaging: AnyObject {
    var requiresRuntimePlayoutProof: Bool { get }

    func activate() throws
    func recover() throws
    func deactivate()
}

@MainActor
protocol BackgroundPlaybackCoordinating: AnyObject {
    func beginTransitionTask()
    func endTransitionTask()
    func publishLiveStream(serverName: String?, isPlaying: Bool)
    func clear()
}

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

    private let playback: any WorldwideAudioPlaybackManaging
    private let backgroundPlayback: any BackgroundPlaybackCoordinating
    private let events: any AudioSessionEventMonitoring
    private var isPrepared = false
    private var playbackIsReady = false
    private var runtimePlayoutIsReady = false
    private var hasRemoteAudio = false
    private var transportIsHealthy = false
    private var isInterrupted = false
    private var requiresExplicitResume = false
    private var playbackErrorText: String?
    private var playbackDiagnosticText: String?
    private var serverName = "Mac mini"
    private var remoteAudioControl: (any WorldwideRemoteAudioControlling)?

    init(
        playback: any WorldwideAudioPlaybackManaging,
        backgroundPlayback: any BackgroundPlaybackCoordinating,
        events: any AudioSessionEventMonitoring
    ) {
        self.playback = playback
        self.backgroundPlayback = backgroundPlayback
        self.events = events

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
    }

    convenience init() {
        self.init(
            playback: WebRTCAudioPlaybackSession(),
            backgroundPlayback: BackgroundPlaybackCoordinator(),
            events: AudioSessionManager()
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
        requiresExplicitResume = false
        playbackErrorText = nil
        playbackDiagnosticText = nil

        do {
            try playback.activate()
            playbackIsReady = true
        } catch {
            // Activation can partially configure the singleton audio session before throwing.
            // Balance it, but keep this lifecycle prepared so screen/signaling can connect and
            // an interruption or route-change notification can retry audio independently.
            playback.deactivate()
            recordPlaybackFailure(
                context: "Initial background audio preparation failed",
                error: error
            )
        }

        events.startObserving()
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

        remoteAudioControl?.setEnabled(false)
        remoteAudioControl = nil
        events.stopObserving()
        playback.deactivate()
        backgroundPlayback.clear()
        isPrepared = false
        playbackIsReady = false
        runtimePlayoutIsReady = false
        hasRemoteAudio = false
        transportIsHealthy = false
        isInterrupted = false
        requiresExplicitResume = false
        playbackErrorText = nil
        playbackDiagnosticText = nil
        publishSnapshot()
    }

    /// Explicit user recovery for interruptions or route removals where iOS declined automatic
    /// resume. Merely receiving more network packets must never clear this gate.
    func resumePlayback() {
        guard isPrepared else { return }
        requiresExplicitResume = false
        recoverPlayback(context: "Audio resume failed")
    }

    /// Accepts proof from the actual output-only RemoteIO device. Signaling, a decoded track, and
    /// WebRTC's global audio gate are not sufficient evidence that the iPhone is producing sound.
    func updateRuntimePlayout(
        isReady: Bool,
        failureMessage: String? = nil,
        diagnostic: String? = nil
    ) {
        guard isPrepared, playback.requiresRuntimePlayoutProof else { return }
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

    private func interruptionBegan() {
        guard isPrepared else { return }
        isInterrupted = true
        publishSnapshot()
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isPrepared else { return }
        isInterrupted = false
        guard shouldResume else {
            requiresExplicitResume = true
            publishSnapshot()
            return
        }
        recoverPlayback(context: "Audio interruption recovery failed")
    }

    private func routeChanged(_ message: String) {
        guard isPrepared else { return }
        if message == "Audio route changed: device unavailable" {
            // Do not leak a loud stream to speakers when headphones disappear. The user can
            // explicitly resume after choosing the intended route.
            requiresExplicitResume = true
            publishSnapshot()
            return
        }
        recoverPlayback(context: "Audio route recovery failed")
    }

    private func recoverPlayback(context: String) {
        guard isPrepared, !isInterrupted else {
            publishSnapshot()
            return
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
        if !playbackIsReady { return "Playback unavailable" }
        if !hasRemoteAudio { return "Waiting for Mac audio" }
        if requiresExplicitResume { return "Paused — resume audio" }
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
