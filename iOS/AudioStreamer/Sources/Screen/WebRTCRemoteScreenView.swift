import SwiftUI
import WebRTCTransport

struct WebRTCRemoteScreenView: UIViewRepresentable {
    let track: WebRTCRemoteVideoTrack?
    var onVideoSizeChanged: (CGSize) -> Void = { _ in }
    var onVideoFrameRendered: (WebRTCVideoRenderObservation) -> Void = { _ in }

    func makeUIView(context: Context) -> WebRTCRemoteVideoView {
        let view = WebRTCRemoteVideoView(frame: .zero)
        view.onVideoSizeChanged = onVideoSizeChanged
        view.onVideoFrameRendered = onVideoFrameRendered
        return view
    }

    func updateUIView(_ view: WebRTCRemoteVideoView, context: Context) {
        view.onVideoSizeChanged = onVideoSizeChanged
        view.onVideoFrameRendered = onVideoFrameRendered
        view.setTrack(track)
    }

    static func dismantleUIView(_ view: WebRTCRemoteVideoView, coordinator: Void) {
        view.onVideoSizeChanged = nil
        view.onVideoFrameRendered = nil
        view.detachTrack()
    }
}
