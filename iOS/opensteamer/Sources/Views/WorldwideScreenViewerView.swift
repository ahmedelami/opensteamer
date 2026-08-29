import SwiftUI
import WebRTCTransport

/// Privacy-bounded full-screen WebRTC renderer and remote-input surface.
///
/// Rendering and input are allowed only while this exact presentation lease remains current and
/// the scene is active. SwiftUI owns presentation and lifecycle; narrow UIKit bridges own video,
/// keyboard responder behavior, and mutually exclusive native gesture recognition.
struct WorldwideScreenViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: WorldwideSessionViewModel
    let lease: WorldwideScreenPresentationLease
    let dismissPresentation: (WorldwideScreenPresentationLease) -> Void
    @State private var videoRendererID = UUID()
    @State private var videoRenderObservation: WebRTCVideoRenderObservation?
    @State private var allowsRemoteInputPresentation = true

    var body: some View {
        ZStack {
            FullscreenViewerLayout {
                GeometryReader { geometry in
                    if allowsRemoteScreenRendering {
                        WebRTCRemoteScreenView(
                            track: viewModel.remoteVideoTrack,
                            // Any decoded-size transition clears touch immediately. Size callbacks
                            // precede presentation and therefore cannot authorize the new mapping.
                            onVideoSizeChanged: { _ in
                                viewModel.discardPendingRemoteScrolls()
                                videoRenderObservation = nil
                            },
                            onVideoFrameRendered: { observation in
                                if videoRenderObservation.map({
                                    observation.frameCount > $0.frameCount
                                }) != false {
                                    videoRenderObservation = observation
                                }
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(.black)
                        .contentShape(Rectangle())
                        .overlay {
                            if let configuration = remotePointerGestureConfiguration(
                                containerSize: geometry.size
                            ) {
                                RemotePointerGestureSurface(
                                    configuration: configuration,
                                    onTap: { location in
                                        forwardTap(
                                            location,
                                            containerSize: configuration.containerSize
                                        )
                                    },
                                    onScrollBegan: { location in
                                        beginRemoteScroll(
                                            at: location,
                                            configuration: configuration
                                        )
                                    },
                                    onScrollChanged: { gestureID, delta in
                                        viewModel.appendRemoteScroll(
                                            gestureID: gestureID,
                                            viewDelta: delta,
                                            containerSize: configuration.containerSize,
                                            viewerVideoSize: configuration.videoSize
                                        )
                                    },
                                    onScrollEnded: { gestureID in
                                        viewModel.endRemoteScroll(gestureID: gestureID)
                                    },
                                    onScrollCancelled: { gestureID in
                                        viewModel.cancelRemoteScroll(gestureID: gestureID)
                                    },
                                    onPrimaryDrag: { start, end in
                                        forwardPrimaryDrag(
                                            from: start,
                                            to: end,
                                            containerSize: configuration.containerSize,
                                            videoSize: configuration.videoSize
                                        )
                                    },
                                    onConfigurationInvalidated: {
                                        viewModel.discardPendingRemoteScrolls()
                                    }
                                )
                            }
                        }
                        .overlay {
                            if viewModel.remoteVideoTrack == nil {
                                ProgressView()
                                    .tint(.white)
                                    .accessibilityLabel(viewModel.stateText)
                            }
                        }
                        .privacySensitive()
                    } else {
                        Color.black
                            .overlay {
                                Image(systemName: "rectangle.slash")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Mac screen hidden for privacy")
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Mac screen video")
                .accessibilityValue(videoRenderAccessibilityValue)
                .accessibilityIdentifier("worldwideMacScreenVideo")
            }

            screenAccessibilityOracles

            RemoteKeyboardInputView(
                inputAvailable: effectiveRemoteInputAvailable,
                focusGeneration: viewModel.focusedInputGeneration,
                isSecure: viewModel.focusedInputIsSecure,
                onInsertText: viewModel.sendRemoteText,
                onDeleteBackward: viewModel.sendRemoteBackspace,
                onReturn: viewModel.sendRemoteReturn
            )
            // The proxy participates in UIKit's responder chain but must never become a visible or
            // hittable second input surface over the remote video.
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task {
            guard Self.allowsScreenPresentation(in: scenePhase) else {
                rejectPresentationAndDismiss()
                return
            }
            let shown = await viewModel.setScreenVisible(true, for: lease)
            guard shown, Self.allowsScreenPresentation(in: scenePhase) else {
                rejectPresentationAndDismiss()
                return
            }
        }
        .onDisappear {
            allowsRemoteInputPresentation = false
            _ = viewModel.beginPassiveScreenTeardown(for: lease)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            hideAndDismiss()
        }
        .onChange(of: remoteVideoTrackIdentity) {
            videoRendererID = UUID()
            videoRenderObservation = nil
        }
    }

    private var screenAccessibilityOracles: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(viewModel.stateText)
                .accessibilityValue(
                    viewModel.screenAcknowledgementOracle?.accessibilityValue
                        ?? "unavailable"
                )
                .accessibilityHint(
                    "\(viewModel.remoteDisplayName), \(viewModel.routeText)"
                )
                .accessibilityIdentifier("worldwideScreenAcknowledgementOracle")

            if effectiveRemoteInputAvailable {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(
                        remoteInputAccessibilityLabel
                    )
                    .accessibilityIdentifier("worldwideRemoteInputEnabled")
            }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }

    private func hideAndDismiss() {
        // Close rendering/input synchronously and start the fail-closed remote Hide transaction.
        // The local cover exits immediately; the model continues requiring an authenticated Hide
        // acknowledgement and closes the session if the Mac cannot prove capture stopped.
        allowsRemoteInputPresentation = false
        _ = viewModel.beginPassiveScreenTeardown(for: lease)
        dismissPresentation(lease)
    }

    private func rejectPresentationAndDismiss() {
        allowsRemoteInputPresentation = false
        _ = viewModel.beginPassiveScreenTeardown(for: lease)
        dismissPresentation(lease)
    }

    private func forwardTap(_ location: CGPoint, containerSize: CGSize) {
        guard effectiveRemoteInputAvailable,
              let renderedVideoSize,
              let normalizedPoint = AspectFitCoordinateMapper.normalizedPoint(
                for: location,
                containerSize: containerSize,
                videoSize: renderedVideoSize
              ) else {
            return
        }
        viewModel.sendRemoteTap(
            normalizedPoint: normalizedPoint,
            viewerVideoSize: renderedVideoSize
        )
    }

    private func beginRemoteScroll(
        at location: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) -> UUID? {
        guard effectiveRemoteInputAvailable,
              viewModel.isRemoteScrollAvailable,
              configuration.inputSessionID
                == viewModel.remoteInputCapability?.inputSessionID,
              renderedVideoSize == configuration.videoSize,
              let normalizedAnchor = AspectFitCoordinateMapper.normalizedPoint(
                for: location,
                containerSize: configuration.containerSize,
                videoSize: configuration.videoSize
              ) else {
            return nil
        }

        return viewModel.beginRemoteScroll(
            normalizedAnchor: normalizedAnchor,
            containerSize: configuration.containerSize,
            viewerVideoSize: configuration.videoSize
        )
    }

    private func forwardPrimaryDrag(
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) {
        guard effectiveRemoteInputAvailable,
              viewModel.isRemotePrimaryDragAvailable,
              let endpoints = RemotePrimaryDragGesturePolicy.normalizedEndpoints(
                startLocation: startLocation,
                endLocation: endLocation,
                containerSize: containerSize,
                videoSize: videoSize
              ) else {
            return
        }
        viewModel.sendRemotePrimaryDrag(
            startNormalizedPoint: endpoints.start,
            endNormalizedPoint: endpoints.end,
            viewerVideoSize: videoSize
        )
    }

    private var effectiveRemoteInputAvailable: Bool {
        viewModel.remoteInputIsAvailable(for: lease)
            && renderedVideoSize != nil
            && allowsRemoteInputPresentation
            && scenePhase == .active
    }

    private func remotePointerGestureConfiguration(
        containerSize: CGSize
    ) -> RemotePointerGestureConfiguration? {
        guard effectiveRemoteInputAvailable,
              let capability = viewModel.remoteInputCapability,
              let track = viewModel.remoteVideoTrack,
              let renderedVideoSize else {
            return nil
        }
        return RemotePointerGestureConfiguration(
            presentationID: lease.id,
            inputSessionID: capability.inputSessionID,
            trackIdentity: ObjectIdentifier(track),
            containerSize: containerSize,
            videoSize: renderedVideoSize,
            allowsPrimaryDrag: viewModel.isRemotePrimaryDragAvailable,
            allowsScroll: viewModel.isRemoteScrollAvailable
        )
    }

    private var remoteInputAccessibilityLabel: String {
        switch (
            viewModel.isRemoteScrollAvailable,
            viewModel.isRemotePrimaryDragAvailable
        ) {
        case (true, true):
            "Tap to click. Swipe to scroll. Hold and drag to select or move."
        case (true, false):
            "Tap to click. Swipe to scroll."
        case (false, true):
            "Tap to click. Hold and drag to select or move."
        case (false, false):
            "Touch control enabled"
        }
    }

    /// Touch is bound only to dimensions observed after a decoded frame was presented by Metal.
    /// `didChangeVideoSize` may run ahead of that visible frame during a format transition.
    private var renderedVideoSize: CGSize? {
        Self.renderedVideoSize(from: videoRenderObservation)
    }

    private var remoteVideoTrackIdentity: ObjectIdentifier? {
        viewModel.remoteVideoTrack.map { ObjectIdentifier($0) }
    }

    static func renderedVideoSize(
        from observation: WebRTCVideoRenderObservation?
    ) -> CGSize? {
        guard let observation,
              observation.width >= 2,
              observation.height >= 2 else {
            return nil
        }
        return CGSize(
            width: observation.width,
            height: observation.height
        )
    }

    private var allowsRemoteScreenRendering: Bool {
        Self.allowsScreenRendering(
            in: scenePhase,
            allowsPresentation: allowsRemoteInputPresentation,
            isScreenVisible: viewModel.screenPresentationIsVisible(lease)
        )
    }

    private var videoRenderAccessibilityValue: String {
        guard let videoRenderObservation else {
            return WorldwideVideoRenderOracleSnapshot(
                rendererID: videoRendererID,
                frameCount: 0,
                timestampNanoseconds: 0,
                width: 0,
                height: 0
            ).accessibilityValue
        }
        return WorldwideVideoRenderOracleSnapshot(
            rendererID: videoRendererID,
            observation: videoRenderObservation
        ).accessibilityValue
    }

    static func allowsScreenPresentation(in scenePhase: ScenePhase) -> Bool {
        scenePhase == .active
    }

    static func allowsScreenRendering(
        in scenePhase: ScenePhase,
        allowsPresentation: Bool,
        isScreenVisible: Bool
    ) -> Bool {
        allowsPresentation && isScreenVisible && scenePhase == .active
    }
}
