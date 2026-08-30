import SwiftUI
import WebRTCTransport

/// SwiftUI wrapper around WebRTC's UIKit renderer and its size/frame observation callbacks.
/// UIKit remains the intentionally small bridge because the native WebRTC video track renders
/// directly into `WebRTCRemoteVideoView`; recreating that path in SwiftUI would add a frame copy.
struct WebRTCRemoteScreenView: UIViewRepresentable {
    let track: WebRTCRemoteVideoTrack?
    var forcePresentationCover = false
    var minimumAcceptedRTPTimestamp: UInt32?
    var proofRTPTimestamps: Set<UInt32> = []
    var markerProof: ScreenVideoInBandMarkerNonce?
    var presentationCoverID: UUID?
    var onVideoSizeChanged: (CGSize) -> Void = { _ in }
    var onVideoFrameRendered: (WebRTCVideoRenderObservation) -> Void = { _ in }
    var onVideoFramePresentedForProof:
        (WebRTCVideoPresentationProofObservation) -> Void = { _ in }
    var onVideoMarkerFramePresentedForProof:
        (WebRTCVideoMarkerPresentationProofObservation) -> Void = { _ in }
    var onPresentationCoverInstalled: (UUID) -> Void = { _ in }

    final class Coordinator {
        var reportedPresentationCoverID: UUID?

        func reportPresentationCoverIfNeeded(
            _ coverID: UUID?,
            handler: (UUID) -> Void
        ) {
            guard let coverID,
                  reportedPresentationCoverID != coverID else {
                return
            }
            reportedPresentationCoverID = coverID
            handler(coverID)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WebRTCRemoteVideoView {
        let view = WebRTCRemoteVideoView(frame: .zero)
        view.onVideoSizeChanged = onVideoSizeChanged
        view.onVideoFrameRendered = onVideoFrameRendered
        view.onVideoFramePresentedForProof = onVideoFramePresentedForProof
        view.onVideoMarkerFramePresentedForProof =
            onVideoMarkerFramePresentedForProof
        view.updatePresentationFence(
            forceCover: forcePresentationCover,
            minimumAcceptedRTPTimestamp: minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: proofRTPTimestamps,
            markerProof: markerProof
        )
        context.coordinator.reportPresentationCoverIfNeeded(
            presentationCoverID,
            handler: onPresentationCoverInstalled
        )
        return view
    }

    func updateUIView(_ view: WebRTCRemoteVideoView, context: Context) {
        view.onVideoSizeChanged = onVideoSizeChanged
        view.onVideoFrameRendered = onVideoFrameRendered
        view.onVideoFramePresentedForProof = onVideoFramePresentedForProof
        view.onVideoMarkerFramePresentedForProof =
            onVideoMarkerFramePresentedForProof
        view.updatePresentationFence(
            forceCover: forcePresentationCover,
            minimumAcceptedRTPTimestamp: minimumAcceptedRTPTimestamp,
            proofRTPTimestamps: proofRTPTimestamps,
            markerProof: markerProof
        )
        context.coordinator.reportPresentationCoverIfNeeded(
            presentationCoverID,
            handler: onPresentationCoverInstalled
        )
        view.setTrack(track)
    }

    static func dismantleUIView(
        _ view: WebRTCRemoteVideoView,
        coordinator: Coordinator
    ) {
        // Clear callbacks before detaching so a late native render cannot retain SwiftUI state.
        view.onVideoSizeChanged = nil
        view.onVideoFrameRendered = nil
        view.onVideoFramePresentedForProof = nil
        view.onVideoMarkerFramePresentedForProof = nil
        view.updatePresentationFence(
            forceCover: true,
            minimumAcceptedRTPTimestamp: nil,
            proofRTPTimestamps: [],
            markerProof: nil
        )
        view.detachTrack()
    }
}
