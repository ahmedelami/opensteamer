import MediaPlayer
import UIKit

/// Minimal interface for borrowing iOS background time while a lifecycle transition settles.
/// Implementations must balance every successful begin with an end and must not treat the lease
/// as permission for indefinite background execution.
@MainActor
protocol TransitionBackgroundTaskCoordinating: AnyObject {
    func beginTransitionTask()
    func endTransitionTask()
}

/// A bounded iOS background-task lease for short state transitions that must finish atomically.
/// It does not grant continuous background execution and must never be used as a media lifetime.
@MainActor
final class AppTransitionBackgroundTaskCoordinator: TransitionBackgroundTaskCoordinating {
    private let name: String
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        self.name = name
    }

    func beginTransitionTask() {
        guard backgroundTask == .invalid else { return }

        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.endTransitionTask()
            }
        }
        guard task != .invalid else { return }
        backgroundTask = task
    }

    func endTransitionTask() {
        guard backgroundTask != .invalid else { return }

        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Publishes privacy-safe lock-screen playback state and owns transition-only background leases.
/// Continuous background eligibility is provided by genuine audio playout, not by this object.
@MainActor
final class BackgroundPlaybackCoordinator {
    private let transitionTask = AppTransitionBackgroundTaskCoordinator(
        name: "AudioStreamerBackgroundPlayback"
    )

    func beginTransitionTask() {
        // This is only transition grace; continuous background eligibility comes from active audio playback.
        transitionTask.beginTransitionTask()
    }

    func endTransitionTask() {
        transitionTask.endTransitionTask()
    }

    func publishLiveStream(serverName: String?, isPlaying: Bool) {
        // Lock-screen metadata is visible outside the unlocked app. Keep it deliberately generic
        // rather than exposing the paired Mac's user-assigned name.
        _ = serverName
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "AudioStreamer",
            MPMediaItemPropertyArtist: "Connected Mac",
            MPMediaItemPropertyAlbumTitle: "Mac audio stream",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        endTransitionTask()
    }
}

extension BackgroundPlaybackCoordinator: TransitionBackgroundTaskCoordinating {}
