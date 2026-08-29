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
    @State private var remotePointerContext: RemotePointerContext?
    @State private var remotePointerHoldTask: Task<Void, Never>?

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
                        .gesture(
                            // One recognizer owns tap, scroll, and held primary drag so an input
                            // sequence can never be classified as more than one remote action.
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    updateRemotePointerGesture(
                                        value,
                                        containerSize: geometry.size
                                    )
                                }
                                .onEnded { value in
                                    endRemotePointerGesture(
                                        value,
                                        containerSize: geometry.size
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
            cancelRemotePointerGesture()
            allowsRemoteInputPresentation = false
            _ = viewModel.beginPassiveScreenTeardown(for: lease)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            cancelRemotePointerGesture()
            hideAndDismiss()
        }
        .onChange(of: viewModel.remoteInputCapability?.inputSessionID) {
            cancelRemotePointerGesture()
        }
        .onChange(of: viewModel.remoteVideoTrack == nil) {
            cancelRemotePointerGesture()
            if viewModel.remoteVideoTrack == nil {
                videoRendererID = UUID()
                videoRenderObservation = nil
            }
        }
        .onChange(of: renderedVideoSize) {
            cancelRemotePointerGesture()
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
                        viewModel.isRemoteScrollAvailable
                            ? (viewModel.isRemotePrimaryDragAvailable
                                ? "Tap to click. Swipe to scroll. Hold and drag to select or move."
                                : "Tap to click. Swipe to scroll.")
                            : (viewModel.isRemotePrimaryDragAvailable
                                ? "Tap to click. Hold and drag to select or move."
                                : "Touch control enabled")
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

    private func updateRemotePointerGesture(
        _ value: DragGesture.Value,
        containerSize: CGSize
    ) {
        guard effectiveRemoteInputAvailable,
              let inputSessionID = viewModel.remoteInputCapability?.inputSessionID,
              let renderedVideoSize else {
            cancelRemotePointerGesture()
            return
        }

        if remotePointerContext == nil {
            guard AspectFitCoordinateMapper.normalizedPoint(
                for: value.startLocation,
                containerSize: containerSize,
                videoSize: renderedVideoSize
            ) != nil else {
                return
            }
            remotePointerContext = RemotePointerContext(
                inputSessionID: inputSessionID,
                containerSize: containerSize,
                videoSize: renderedVideoSize,
                startLocation: value.startLocation,
                previousLocation: value.startLocation,
                mode: .pending
            )
            scheduleRemotePrimaryDragArm()
        }

        guard var context = remotePointerContext,
              context.inputSessionID == inputSessionID,
              context.containerSize == containerSize,
              context.videoSize == renderedVideoSize else {
            cancelRemotePointerGesture()
            return
        }

        switch context.mode {
        case .pending:
            if RemotePointerGesturePolicy.exceededMovementThreshold(
                from: context.startLocation,
                to: value.location
            ) {
                remotePointerHoldTask?.cancel()
                remotePointerHoldTask = nil
                if viewModel.isRemoteScrollAvailable {
                    context.mode = .scrolling
                    forwardScroll(
                        anchorLocation: context.startLocation,
                        from: context.startLocation,
                        to: value.location,
                        containerSize: context.containerSize,
                        videoSize: context.videoSize
                    )
                } else {
                    // Movement already disproved a tap. Do not reinterpret it as a click merely
                    // because the connected host does not advertise scrolling.
                    context.mode = .cancelled
                }
            }

        case .scrolling:
            forwardScroll(
                anchorLocation: context.startLocation,
                from: context.previousLocation,
                to: value.location,
                containerSize: context.containerSize,
                videoSize: context.videoSize
            )

        case .primaryDragging, .cancelled:
            break
        }

        context.previousLocation = value.location
        remotePointerContext = context
    }

    private func endRemotePointerGesture(
        _ value: DragGesture.Value,
        containerSize: CGSize
    ) {
        defer { cancelRemotePointerGesture() }
        guard let context = remotePointerContext,
              context.inputSessionID == viewModel.remoteInputCapability?.inputSessionID,
              context.containerSize == containerSize,
              let renderedVideoSize,
              context.videoSize == renderedVideoSize else {
            return
        }

        switch context.mode {
        case .pending:
            if RemotePointerGesturePolicy.exceededMovementThreshold(
                from: context.startLocation,
                to: value.location
            ) {
                if viewModel.isRemoteScrollAvailable {
                    forwardScroll(
                        anchorLocation: context.startLocation,
                        from: context.previousLocation,
                        to: value.location,
                        containerSize: context.containerSize,
                        videoSize: context.videoSize
                    )
                }
            } else {
                forwardTap(value.location, containerSize: context.containerSize)
            }

        case .scrolling:
            forwardScroll(
                anchorLocation: context.startLocation,
                from: context.previousLocation,
                to: value.location,
                containerSize: context.containerSize,
                videoSize: context.videoSize
            )

        case .primaryDragging:
            if hypot(
                value.location.x - context.startLocation.x,
                value.location.y - context.startLocation.y
            ) >= RemotePrimaryDragGesturePolicy.minimumMovement {
                forwardPrimaryDrag(
                    from: context.startLocation,
                    to: value.location,
                    containerSize: context.containerSize,
                    videoSize: context.videoSize
                )
            } else {
                forwardTap(value.location, containerSize: context.containerSize)
            }

        case .cancelled:
            break
        }
    }

    private func scheduleRemotePrimaryDragArm() {
        remotePointerHoldTask?.cancel()
        remotePointerHoldTask = Task { @MainActor in
            try? await Task.sleep(for: RemotePointerGesturePolicy.holdDuration)
            guard !Task.isCancelled,
                  var context = remotePointerContext,
                  context.mode == .pending,
                  viewModel.isRemotePrimaryDragAvailable,
                  context.inputSessionID == viewModel.remoteInputCapability?.inputSessionID,
                  renderedVideoSize == context.videoSize else {
                return
            }
            context.mode = .primaryDragging
            remotePointerContext = context
            remotePointerHoldTask = nil
        }
    }

    private func cancelRemotePointerGesture() {
        remotePointerHoldTask?.cancel()
        remotePointerHoldTask = nil
        remotePointerContext = nil
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

    private func forwardScroll(
        anchorLocation: CGPoint,
        from previousLocation: CGPoint,
        to location: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) {
        guard effectiveRemoteInputAvailable,
              viewModel.isRemoteScrollAvailable,
              let sample = RemotePointerGesturePolicy.normalizedScrollSample(
                  anchorLocation: anchorLocation,
                  previousLocation: previousLocation,
                  location: location,
                  containerSize: containerSize,
                  videoSize: videoSize
              ) else {
            return
        }
        viewModel.sendRemoteScroll(
            anchorNormalizedPoint: sample.anchor,
            deltaX: sample.deltaX,
            deltaY: sample.deltaY,
            viewerVideoSize: videoSize
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

/// Snapshot of gesture ownership that must remain unchanged until the touch completes.
private struct RemotePointerContext {
    enum Mode: Equatable {
        case pending
        case scrolling
        case primaryDragging
        case cancelled
    }

    let inputSessionID: UUID
    let containerSize: CGSize
    let videoSize: CGSize
    let startLocation: CGPoint
    var previousLocation: CGPoint
    var mode: Mode
}
