import SwiftUI
import WebRTCTransport

/// SwiftUI wrapper around WebRTC's UIKit renderer and its size/frame observation callbacks.
/// UIKit remains the intentionally small bridge because the native WebRTC video track renders
/// directly into `WebRTCRemoteVideoView`; recreating that path in SwiftUI would add a frame copy.
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
        // Clear callbacks before detaching so a late native render cannot retain SwiftUI state.
        view.onVideoSizeChanged = nil
        view.onVideoFrameRendered = nil
        view.detachTrack()
    }
}
