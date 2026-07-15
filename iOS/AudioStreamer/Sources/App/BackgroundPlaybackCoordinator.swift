import MediaPlayer
import UIKit

@MainActor
final class BackgroundPlaybackCoordinator {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func beginTransitionTask() {
        guard backgroundTask == .invalid else { return }

        // This is only transition grace; continuous background eligibility comes from active audio playback.
        let task = UIApplication.shared.beginBackgroundTask(withName: "AudioStreamerBackgroundPlayback") { [weak self] in
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
