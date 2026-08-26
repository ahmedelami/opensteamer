import SwiftUI
import WebRTCTransport

/// Privacy-bounded full-screen WebRTC renderer and remote-input surface.
///
/// Rendering and input are allowed only while this exact presentation lease remains current and
/// the scene is active. UIKit is used only by the nested WebRTC renderer and keyboard responder
/// bridges; SwiftUI retains ownership of presentation, gestures, and lifecycle state.
struct WorldwideScreenViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: WorldwideSessionViewModel
    let lease: WorldwideScreenPresentationLease
    let dismissPresentation: (WorldwideScreenPresentationLease) -> Void
    @State private var videoRendererID = UUID()
    @State private var videoRenderObservation: WebRTCVideoRenderObservation?
    @State private var allowsRemoteInputPresentation = true
    @State private var primaryDragContext: PrimaryDragContext?

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
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    forwardTap(value.location, containerSize: geometry.size)
                                }
                        )
                        .simultaneousGesture(
                            // Long press distinguishes intentional selection/drag from an ordinary
                            // tap. Capturing the input-session ID and geometry at recognition time
                            // fences a gesture that outlives focus, peer, or orientation changes.
                            LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
                                .sequenced(
                                    before: DragGesture(
                                        minimumDistance: RemotePrimaryDragGesturePolicy.minimumMovement,
                                        coordinateSpace: .local
                                    )
                                )
                                .onChanged { value in
                                    guard case .second(true, .some) = value,
                                          primaryDragContext == nil,
                                          viewModel.isRemotePrimaryDragAvailable,
                                          let inputSessionID = viewModel.remoteInputCapability?.inputSessionID,
                                          let renderedVideoSize else {
                                        return
                                    }
                                    primaryDragContext = PrimaryDragContext(
                                        inputSessionID: inputSessionID,
                                        containerSize: geometry.size,
                                        videoSize: renderedVideoSize
                                    )
                                }
                                .onEnded { value in
                                    defer { primaryDragContext = nil }
                                    guard case .second(true, let drag?) = value,
                                          let context = primaryDragContext,
                                          context.inputSessionID == viewModel.remoteInputCapability?.inputSessionID,
                                          context.containerSize == geometry.size,
                                          let renderedVideoSize,
                                          context.videoSize == renderedVideoSize else {
                                        return
                                    }
                                    forwardPrimaryDrag(
                                        from: drag.startLocation,
                                        to: drag.location,
                                        containerSize: context.containerSize,
                                        videoSize: context.videoSize
                                    )
                                }
                        )
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
            primaryDragContext = nil
            allowsRemoteInputPresentation = false
            _ = viewModel.beginPassiveScreenTeardown(for: lease)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            primaryDragContext = nil
            hideAndDismiss()
        }
        .onChange(of: viewModel.remoteInputCapability?.inputSessionID) {
            primaryDragContext = nil
        }
        .onChange(of: viewModel.remoteVideoTrack == nil) {
            primaryDragContext = nil
            if viewModel.remoteVideoTrack == nil {
                videoRendererID = UUID()
                videoRenderObservation = nil
            }
        }
        .onChange(of: renderedVideoSize) {
            primaryDragContext = nil
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
                        viewModel.isRemotePrimaryDragAvailable
                            ? "Tap to click. Hold and drag to select or move."
                            : "Touch control enabled"
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

    /// Touch is bound only to dimensions observed after a decoded frame was presented by Metal.
    /// `didChangeVideoSize` may run ahead of that visible frame during a format transition.
    private var renderedVideoSize: CGSize? {
        Self.renderedVideoSize(from: videoRenderObservation)
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

/// Snapshot of gesture ownership that must remain unchanged until a primary drag completes.
private struct PrimaryDragContext: Equatable {
    let inputSessionID: UUID
    let containerSize: CGSize
    let videoSize: CGSize
}
