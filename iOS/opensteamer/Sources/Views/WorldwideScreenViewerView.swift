import SwiftUI
import Streaming
import WebRTCTransport

/// Privacy-bounded full-screen WebRTC renderer and remote-input surface.
///
/// Remote pixels and input are exposed only while this exact presentation lease remains current
/// and the scene is active. The renderer stays mounted behind an opaque privacy cover during a
/// transient inactive phase so returning active does not tear down and rebuild a healthy stream.
/// SwiftUI owns presentation and lifecycle; narrow UIKit bridges own video, keyboard responder
/// behavior, and mutually exclusive native gesture recognition.
struct WorldwideScreenViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: WorldwideSessionViewModel
    let lease: WorldwideScreenPresentationLease
    let dismissPresentation: (WorldwideScreenPresentationLease) -> Void
    @State private var videoRendererID = UUID()
    @State private var videoRenderObservation: WebRTCVideoRenderObservation?
    @State private var allowsRemoteInputPresentation = true
    @State private var focusedWindowResizeGhostFrame: CGRect?

    var body: some View {
        ZStack {
            FullscreenViewerLayout {
                GeometryReader { geometry in
                    if keepsRemoteScreenRendererMounted {
                        WebRTCRemoteScreenView(
                            track: presentedRemoteVideoTrack,
                            forcePresentationCover:
                                screenMediaFence?.forceCover == true,
                            forcePrivacyCover: requiresLocalPrivacyCover,
                            minimumAcceptedRTPTimestamp:
                                screenMediaFence?.minimumAcceptedRTPTimestamp,
                            proofRTPTimestamps:
                                screenMediaFence?.proofRTPTimestamps ?? [],
                            markerProof: screenMediaFence?.markerProof,
                            presentationCoverID:
                                screenMediaFence?.forceCover == true
                                    ? screenMediaFence?.coverID
                                    : nil,
                            // Any decoded-size transition clears touch immediately. Size callbacks
                            // precede presentation and therefore cannot authorize the new mapping.
                            onVideoSizeChanged: { size in
                                focusedWindowResizeGhostFrame = nil
                                viewModel.cancelFocusedWindowResize()
                                viewModel.discardPendingRemoteScrolls()
                                videoRenderObservation = nil
                                viewModel.screenVideoPresentationGeometryDidChange(
                                    to: size,
                                    for: lease
                                )
                            },
                            onVideoFrameRendered: { observation in
                                if videoRenderObservation.map({
                                    observation.frameCount > $0.frameCount
                                }) != false {
                                    videoRenderObservation = observation
                                }
                                viewModel.screenVideoFrameDidRender(
                                    observation,
                                    for: lease
                                )
                            },
                            onVideoFramePresentedForProof: { observation in
                                viewModel.screenVideoFrameDidPresentForProof(
                                    observation,
                                    for: lease
                                )
                            },
                            onVideoMarkerFramePresentedForProof: { observation in
                                viewModel.screenVideoMarkerFrameDidPresentForProof(
                                    observation,
                                    for: lease
                                )
                            },
                            onPresentationCoverInstalled: { coverID in
                                // The UIKit bridge has synchronously placed its opaque cover. Hop
                                // out of UIViewRepresentable reconciliation before publishing the
                                // protocol-side acknowledgement task.
                                Task { @MainActor in
                                    viewModel.screenMediaPresentationCoverDidInstall(
                                        coverID: coverID,
                                        for: lease
                                    )
                                }
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(.black)
                        .overlay {
                            if requiresLocalPrivacyCover {
                                Color.black
                                    .accessibilityLabel(
                                        "Mac screen covered while the app is inactive"
                                    )
                            }
                        }
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
                                    onFocusedWindowSelection: { location in
                                        selectWindowForFocusedResize(
                                            at: location,
                                            configuration: configuration
                                        )
                                    },
                                    onFocusedWindowResizePreview: {
                                        generation, start, end in
                                        previewFocusedWindowResize(
                                            targetGeneration: generation,
                                            from: start,
                                            to: end,
                                            configuration: configuration
                                        )
                                    },
                                    onFocusedWindowResizeCommit: {
                                        generation, start, end in
                                        commitFocusedWindowResize(
                                            targetGeneration: generation,
                                            from: start,
                                            to: end,
                                            configuration: configuration
                                        )
                                    },
                                    onFocusedWindowResizeCancelled: {
                                        focusedWindowResizeGhostFrame = nil
                                    },
                                    onConfigurationInvalidated: {
                                        focusedWindowResizeGhostFrame = nil
                                        viewModel.cancelFocusedWindowResize()
                                        viewModel.discardPendingRemoteScrolls()
                                    }
                                )
                            }
                        }
                        .overlay {
                            focusedWindowResizeOverlay(
                                containerSize: geometry.size
                            )
                        }
                        .overlay {
                            if viewModel.remoteVideoTrack == nil {
                                ProgressView()
                                    .tint(.white)
                                    .accessibilityLabel(viewModel.stateText)
                            }
                        }
                        .overlay {
                            if let statusText = screenMediaFence?.statusText,
                               screenMediaFence?.forceCover == true {
                                VStack(spacing: 10) {
                                    ProgressView()
                                        .tint(.white)
                                    Text(statusText)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                                .padding(18)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(
                                    "worldwideScreenMediaSuspensionStatus"
                                )
                            }
                        }
                        .overlay(alignment: .top) {
                            if let statusText = screenPipelineFailureText {
                                Text(statusText)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(.black.opacity(0.82), in: Capsule())
                                    .padding(.top, 12)
                                    .allowsHitTesting(false)
                                    .accessibilityIdentifier(
                                        "worldwideScreenClientPipelineStatus"
                                    )
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            focusedWindowResizeButton(
                                containerSize: geometry.size
                            )
                        }
                        .onChange(of: geometry.size) { oldSize, newSize in
                            guard oldSize != newSize,
                                  viewModel.focusedWindowResizeState.isActive else {
                                return
                            }
                            focusedWindowResizeGhostFrame = nil
                            viewModel.focusedWindowResizeContainerGeometryDidChange(
                                to: newSize,
                                for: lease
                            )
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
                inputAvailable: remoteInputPresentationAvailability.keyboard,
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
            focusedWindowResizeGhostFrame = nil
            viewModel.cancelFocusedWindowResize()
            allowsRemoteInputPresentation = false
            _ = viewModel.beginPassiveScreenTeardown(for: lease)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                focusedWindowResizeGhostFrame = nil
                viewModel.cancelFocusedWindowResize()
            }
            guard Self.shouldTearDownPresentation(in: newPhase) else { return }
            hideAndDismiss()
        }
        .onChange(of: remoteVideoTrackIdentity) {
            focusedWindowResizeGhostFrame = nil
            viewModel.cancelFocusedWindowResize()
            videoRendererID = UUID()
            videoRenderObservation = nil
        }
        .onChange(of: viewModel.remoteInputCapability) { _, capability in
            guard viewModel.focusedWindowResizeState.isActive,
                  capability?.supportsFocusedWindowResize != true
                    || capability?.inputSessionID
                        != viewModel.focusedWindowResizeState.interaction?.binding.inputSessionID
                    || capability?.screenRequestID
                        != viewModel.focusedWindowResizeState.interaction?.binding.screenRequestID else {
                return
            }
            focusedWindowResizeGhostFrame = nil
            viewModel.cancelFocusedWindowResize()
        }
        .onChange(of: viewModel.isFocusedWindowResizeAvailable) { _, isAvailable in
            guard !isAvailable,
                  viewModel.focusedWindowResizeState.isActive else { return }
            focusedWindowResizeGhostFrame = nil
            viewModel.cancelFocusedWindowResize()
        }
        .onChange(of: viewModel.focusedWindowResizeState) { oldState, newState in
            if !newState.isActive
                || (oldState.interaction?.pending != nil
                    && newState.interaction?.pending == nil) {
                focusedWindowResizeGhostFrame = nil
            }
        }
        .onChange(of: screenMediaFence?.proofRequestRevision) {
            guard let videoRenderObservation else { return }
            viewModel.screenVideoFrameDidRender(
                videoRenderObservation,
                for: lease
            )
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

            if remoteInputPresentationAvailability.pointer {
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

    private var screenPipelineFailureText: String? {
        switch viewModel.screenLivenessDiagnosticSnapshot.state {
        case .inboundRTPStalled, .decodeStalled, .presentationStalled:
            viewModel.screenLivenessStatusText
        case .intentionallyCovered, .covered, .trackMissing,
             .awaitingEvidence, .presentingUnchanged, .presentingLive:
            nil
        }
    }

    private func hideAndDismiss() {
        // Close rendering/input synchronously and start the fail-closed remote Hide transaction.
        // The local cover exits immediately; the model continues requiring an authenticated Hide
        // acknowledgement and closes the session if the Mac cannot prove capture stopped.
        focusedWindowResizeGhostFrame = nil
        viewModel.cancelFocusedWindowResize()
        allowsRemoteInputPresentation = false
        _ = viewModel.beginPassiveScreenTeardown(for: lease)
        dismissPresentation(lease)
    }

    private func rejectPresentationAndDismiss() {
        focusedWindowResizeGhostFrame = nil
        viewModel.cancelFocusedWindowResize()
        allowsRemoteInputPresentation = false
        _ = viewModel.beginPassiveScreenTeardown(for: lease)
        dismissPresentation(lease)
    }

    private func forwardTap(_ location: CGPoint, containerSize: CGSize) {
        guard remoteInputPresentationAvailability.pointer,
              !viewModel.focusedWindowResizeState.isActive,
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
        guard remoteInputPresentationAvailability.pointer,
              !viewModel.focusedWindowResizeState.isActive,
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
        guard remoteInputPresentationAvailability.pointer,
              !viewModel.focusedWindowResizeState.isActive,
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

    private func selectWindowForFocusedResize(
        at location: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard viewModel.focusedWindowResizeState.isActive,
              let normalizedPoint = AspectFitCoordinateMapper.normalizedPoint(
                  for: location,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ) else {
            return
        }
        focusedWindowResizeGhostFrame = nil
        viewModel.selectWindowForFocusedResize(
            at: normalizedPoint,
            for: lease,
            containerSize: configuration.containerSize,
            viewerVideoSize: configuration.videoSize
        )
    }

    private func previewFocusedWindowResize(
        targetGeneration: UUID,
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard let interaction = viewModel.focusedWindowResizeState.interaction,
              interaction.pending == nil,
              let target = interaction.target,
              target.generation == targetGeneration,
              let minimumSize = FocusedWindowResizeGeometry.minimumRetainedSize(
                  for: Self.cgRect(from: target.normalizedFrame)
              ),
              let start = AspectFitCoordinateMapper.normalizedPoint(
                  for: startLocation,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ),
              let end = AspectFitCoordinateMapper.clampedNormalizedPoint(
                  for: endLocation,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ),
              let proposal = FocusedWindowResizeGeometry.proposedFrame(
                  original: Self.cgRect(from: target.normalizedFrame),
                  start: start,
                  end: end,
                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                  minimumSize: minimumSize,
                  containmentTolerance: 0
              ) else {
            focusedWindowResizeGhostFrame = nil
            return
        }
        focusedWindowResizeGhostFrame = proposal.frame
    }

    private func commitFocusedWindowResize(
        targetGeneration: UUID,
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard let start = AspectFitCoordinateMapper.normalizedPoint(
                  for: startLocation,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ),
              let end = AspectFitCoordinateMapper.clampedNormalizedPoint(
                  for: endLocation,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ) else {
            focusedWindowResizeGhostFrame = nil
            return
        }
        viewModel.commitFocusedWindowResize(
            targetGeneration: targetGeneration,
            startNormalizedPoint: start,
            endNormalizedPoint: end,
            for: lease,
            containerSize: configuration.containerSize,
            viewerVideoSize: configuration.videoSize
        )
    }

    @ViewBuilder
    private func focusedWindowResizeOverlay(containerSize: CGSize) -> some View {
        if viewModel.focusedWindowResizeState.isActive,
           let videoSize = renderedVideoSize {
            let targetRect = viewModel.focusedWindowResizeState.interaction?.target.flatMap {
                AspectFitCoordinateMapper.viewRect(
                    forNormalizedRect: Self.cgRect(from: $0.normalizedFrame),
                    containerSize: containerSize,
                    videoSize: videoSize
                )
            }
            let ghostRect = focusedWindowResizeGhostFrame.flatMap {
                AspectFitCoordinateMapper.viewRect(
                    forNormalizedRect: $0,
                    containerSize: containerSize,
                    videoSize: videoSize
                )
            }
            FocusedWindowResizeOverlay(
                targetRect: targetRect,
                ghostRect: ghostRect
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func focusedWindowResizeButton(containerSize: CGSize) -> some View {
        if (viewModel.focusedWindowResizeState.isActive
            || viewModel.isFocusedWindowResizeAvailable),
           remoteInputPresentationAvailability.pointer,
           let renderedVideoSize {
            Button {
                focusedWindowResizeGhostFrame = nil
                if viewModel.focusedWindowResizeState.isActive {
                    viewModel.cancelFocusedWindowResize()
                } else {
                    _ = viewModel.beginFocusedWindowResize(
                        for: lease,
                        containerSize: containerSize,
                        viewerVideoSize: renderedVideoSize
                    )
                }
            } label: {
                Label(
                    viewModel.focusedWindowResizeState.isActive ? "Done" : "Resize",
                    systemImage: viewModel.focusedWindowResizeState.isActive
                        ? "checkmark"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.focusedWindowResizeState.isActive ? .green : .blue)
            .controlSize(.large)
            .padding(.trailing, 16)
            .padding(.bottom, 14)
            .accessibilityIdentifier("worldwideFocusedWindowResizeButton")
            .accessibilityHint(
                viewModel.focusedWindowResizeState.isActive
                    ? "Ends focused-window resize mode"
                    : "Selects and resizes a Mac window"
            )
        }
    }

    private static func cgRect(from rect: WebRTCNormalizedRect) -> CGRect {
        CGRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    private var remoteInputPresentationAvailability:
        RemoteInputPresentationAvailability {
        Self.remoteInputPresentationAvailability(
            remoteInputAvailable: viewModel.remoteInputIsAvailable(for: lease),
            renderedVideoSize: renderedVideoSize,
            allowsPresentation: allowsRemoteInputPresentation,
            screenMediaIsCovered: screenMediaFence?.forceCover == true,
            scenePhase: scenePhase
        )
    }

    private var screenMediaFence: WorldwideScreenMediaViewerFence? {
        viewModel.screenMediaViewerFence(for: lease)
    }

    private func remotePointerGestureConfiguration(
        containerSize: CGSize
    ) -> RemotePointerGestureConfiguration? {
        guard remoteInputPresentationAvailability.pointer,
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
            allowsScroll: viewModel.isRemoteScrollAvailable,
            interactionMode: remotePointerInteractionMode(
                containerSize: containerSize,
                videoSize: renderedVideoSize,
                capability: capability,
                track: track
            )
        )
    }

    private func remotePointerInteractionMode(
        containerSize: CGSize,
        videoSize: CGSize,
        capability: WebRTCInputCapability,
        track: WebRTCRemoteVideoTrack
    ) -> RemotePointerGestureInteractionMode {
        guard let interaction = viewModel.focusedWindowResizeState.interaction else {
            return .standard
        }
        let binding = interaction.binding
        guard binding.lease == lease,
              binding.inputSessionID == capability.inputSessionID,
              binding.screenRequestID == capability.screenRequestID,
              binding.trackIdentity == ObjectIdentifier(track),
              binding.containerSize == containerSize,
              binding.viewerVideoSize == videoSize else {
            return .focusedWindowResizePending
        }
        if interaction.pending != nil {
            return .focusedWindowResizePending
        }
        guard let target = interaction.target,
              let targetViewFrame = AspectFitCoordinateMapper.viewRect(
                  forNormalizedRect: Self.cgRect(from: target.normalizedFrame),
                  containerSize: containerSize,
                  videoSize: videoSize
              ) else {
            return .focusedWindowResize(target: nil)
        }
        return .focusedWindowResize(
            target: RemotePointerResizeTarget(
                generation: target.generation,
                viewFrame: targetViewFrame
            )
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
        presentedRemoteVideoTrack.map { ObjectIdentifier($0) }
    }

    private var presentedRemoteVideoTrack: WebRTCRemoteVideoTrack? {
        viewModel.screenVideoTrack(for: lease)
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

    struct RemoteInputPresentationAvailability: Equatable {
        let keyboard: Bool
        let pointer: Bool
    }

    /// A decoded-size change revokes pointer geometry until Metal presents a frame in the new
    /// format. Keyboard actions carry an independently authenticated focus generation and no
    /// video coordinates, so tying the responder to that geometry gap needlessly dismisses the
    /// software keyboard during ordinary quality adaptation.
    static func remoteInputPresentationAvailability(
        remoteInputAvailable: Bool,
        renderedVideoSize: CGSize?,
        allowsPresentation: Bool,
        screenMediaIsCovered: Bool,
        scenePhase: ScenePhase
    ) -> RemoteInputPresentationAvailability {
        let keyboard = remoteInputAvailable
            && allowsPresentation
            && !screenMediaIsCovered
            && scenePhase == .active
        return RemoteInputPresentationAvailability(
            keyboard: keyboard,
            pointer: keyboard && renderedVideoSize != nil
        )
    }

    private var keepsRemoteScreenRendererMounted: Bool {
        Self.keepsScreenRendererMounted(
            allowsPresentation: allowsRemoteInputPresentation,
            isScreenVisible:
                viewModel.screenPresentationShouldRemainMounted(lease)
        )
    }

    private var requiresLocalPrivacyCover: Bool {
        !Self.allowsScreenRendering(
            in: scenePhase,
            allowsPresentation: allowsRemoteInputPresentation,
            isScreenVisible:
                viewModel.screenPresentationShouldRemainMounted(lease)
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

    static func shouldTearDownPresentation(in scenePhase: ScenePhase) -> Bool {
        scenePhase == .background
    }

    static func keepsScreenRendererMounted(
        allowsPresentation: Bool,
        isScreenVisible: Bool
    ) -> Bool {
        allowsPresentation && isScreenVisible
    }

    static func allowsScreenRendering(
        in scenePhase: ScenePhase,
        allowsPresentation: Bool,
        isScreenVisible: Bool
    ) -> Bool {
        allowsPresentation && isScreenVisible && scenePhase == .active
    }
}

private struct FocusedWindowResizeOverlay: View {
    let targetRect: CGRect?
    let ghostRect: CGRect?

    var body: some View {
        ZStack {
            if let targetRect {
                Path(targetRect)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    .shadow(color: .black.opacity(0.8), radius: 2)
                Path { path in
                    let midpoint = CGPoint(x: targetRect.midX, y: targetRect.midY)
                    path.move(to: CGPoint(x: midpoint.x, y: targetRect.minY))
                    path.addLine(to: CGPoint(x: midpoint.x, y: targetRect.maxY))
                    path.move(to: CGPoint(x: targetRect.minX, y: midpoint.y))
                    path.addLine(to: CGPoint(x: targetRect.maxX, y: midpoint.y))
                }
                .stroke(
                    .white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 6])
                )
            }

            if let ghostRect {
                Path(ghostRect)
                    .fill(.cyan.opacity(0.12))
                Path(ghostRect)
                    .stroke(
                        .white,
                        style: StrokeStyle(lineWidth: 3, lineJoin: .round, dash: [9, 6])
                    )
                    .shadow(color: .black.opacity(0.9), radius: 2)
            }
        }
    }
}
