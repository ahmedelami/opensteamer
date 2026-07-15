#if os(iOS)
@preconcurrency import LiveKitWebRTC
import UIKit

/// The narrow UIKit boundary used by the SwiftUI iPhone client to render a remote track.
@MainActor
public final class WebRTCRemoteVideoView: UIView, LKRTCVideoViewDelegate {
    private let renderer = LKRTCMTLVideoView(frame: .zero)
    private var currentTrack: WebRTCRemoteVideoTrack?
    private var bindingGeneration: UInt64 = 0
    private var currentVideoSize = CGSize.zero

    /// Reports the decoded frame size used by the aspect-fit renderer.
    ///
    /// The SwiftUI owner uses this exact size to distinguish video pixels from the
    /// renderer's letterbox area before forwarding a remote-input coordinate.
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureRenderer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRenderer()
    }

    public func setTrack(_ track: WebRTCRemoteVideoTrack?) {
        guard currentTrack !== track else { return }
        bindingGeneration &+= 1
        let generation = bindingGeneration

        publishVideoSize(.zero)

        // These mutations are synchronous on MainActor. The generation guard documents and
        // enforces last-bind-wins if this boundary later gains an asynchronous preparation step.
        currentTrack?.removeRenderer(renderer)
        guard generation == bindingGeneration else { return }
        currentTrack = track
        track?.addRenderer(renderer)
    }

    public func detachTrack() {
        setTrack(nil)
        renderer.renderFrame(nil)
    }

    nonisolated public func videoView(
        _ videoView: LKRTCVideoRenderer,
        didChangeVideoSize size: CGSize
    ) {
        Task { @MainActor [weak self] in
            self?.publishVideoSize(size)
        }
    }

    private func configureRenderer() {
        backgroundColor = .black
        renderer.backgroundColor = .black
        renderer.videoContentMode = .scaleAspectFit
        renderer.delegate = self
        renderer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func publishVideoSize(_ size: CGSize) {
        guard size != currentVideoSize else { return }
        currentVideoSize = size
        onVideoSizeChanged?(size)
    }
}
#endif
