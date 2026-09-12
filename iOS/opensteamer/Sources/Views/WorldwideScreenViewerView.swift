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
                            // Any decoded-size transition clears touch immediately. Callback order
                            // is not authoritative; only a matching Metal presentation can rebind.
                            onVideoSizeChanged: { size in
                                if Self.videoSizeCallbackRevokesPresentedGeometry(size) {
                                    focusedWindowResizeGhostFrame = nil
                                    viewModel.discardPendingRemoteScrolls()
                                    videoRenderObservation = nil
                                    return
                                }
                                viewModel.screenVideoPresentationGeometryDidChange(
                                    to: size,
                                    for: lease
                                )
                            },
                            onVideoPresentationInvalidated: { token, invalidation in
                                focusedWindowResizeGhostFrame = nil
                                viewModel.discardPendingRemoteScrolls()
                                videoRenderObservation = nil
                                viewModel.screenVideoPresentationDidInvalidate(
                                    invalidation,
                                    token: token,
                                    for: lease
                                )
                            },
                            onVideoFrameRendered: { observation, token in
                                viewModel.focusedWindowMoveVideoFrameDidPresent(
                                    size: CGSize(
                                        width: observation.width,
                                        height: observation.height
                                    ),
                                    token: token,
                                    for: lease
                                )
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
                                    onFocusedWindowMovePreview: { generation, start, end in
                                        previewFocusedWindowMove(
                                            targetGeneration: generation,
                                            from: start,
                                            to: end,
                                            configuration: configuration
                                        )
                                    },
                                    onFocusedWindowMoveCommit: { generation, start, end in
                                        commitFocusedWindowMove(
                                            targetGeneration: generation,
                                            from: start,
                                            to: end,
                                            configuration: configuration
                                        )
                                    },
                                    onFocusedWindowMoveCancelled: {
                                        focusedWindowResizeGhostFrame = nil
                                    },
                                    onConfigurationInvalidated: {
                                        focusedWindowResizeGhostFrame = nil
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
                            focusedWindowControls(
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
            guard let interaction = viewModel.focusedWindowResizeState.interaction else {
                return
            }
            let supportsMode = interaction.mode == .move
                ? capability?.supportsFocusedWindowMove == true
                : capability?.supportsFocusedWindowResize == true
            guard !supportsMode
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
                  viewModel.focusedWindowResizeState.interaction?.mode == .resize else { return }
            focusedWindowResizeGhostFrame = nil
            viewModel.cancelFocusedWindowResize()
        }
        .onChange(of: viewModel.isFocusedWindowMoveAvailable) { _, isAvailable in
            guard !isAvailable,
                  viewModel.focusedWindowResizeState.interaction?.mode == .move else { return }
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
        if viewModel.focusedWindowResizeState.interaction?.mode == .move {
            viewModel.selectWindowForFocusedMove(
                at: normalizedPoint,
                for: lease,
                containerSize: configuration.containerSize,
                viewerVideoSize: configuration.videoSize
            )
        } else {
            viewModel.selectWindowForFocusedResize(
                at: normalizedPoint,
                for: lease,
                containerSize: configuration.containerSize,
                viewerVideoSize: configuration.videoSize
            )
        }
    }

    private func previewFocusedWindowResize(
        targetGeneration: UUID,
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard let interaction = viewModel.focusedWindowResizeState.interaction,
              interaction.mode == .resize,
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

    private func previewFocusedWindowMove(
        targetGeneration: UUID,
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard let interaction = viewModel.focusedWindowResizeState.interaction,
              interaction.mode == .move,
              interaction.pending == nil,
              let target = interaction.target,
              target.generation == targetGeneration,
              let endpoints = RemotePrimaryDragGesturePolicy.normalizedEndpoints(
                  startLocation: startLocation,
                  endLocation: endLocation,
                  containerSize: configuration.containerSize,
                  videoSize: configuration.videoSize
              ) else {
            focusedWindowResizeGhostFrame = nil
            return
        }
        focusedWindowResizeGhostFrame = Self.focusedWindowMovePreviewFrame(
            target: target,
            start: endpoints.start,
            end: endpoints.end,
            allowsRecoverableOffscreen: interaction.binding.allowsRecoverableOffscreenMove
        )
    }

    private func commitFocusedWindowMove(
        targetGeneration: UUID,
        from startLocation: CGPoint,
        to endLocation: CGPoint,
        configuration: RemotePointerGestureConfiguration
    ) {
        guard let endpoints = RemotePrimaryDragGesturePolicy.normalizedEndpoints(
            startLocation: startLocation,
            endLocation: endLocation,
            containerSize: configuration.containerSize,
            videoSize: configuration.videoSize
        ) else {
            focusedWindowResizeGhostFrame = nil
            return
        }
        viewModel.commitFocusedWindowMove(
            targetGeneration: targetGeneration,
            startNormalizedPoint: endpoints.start,
            endNormalizedPoint: endpoints.end,
            for: lease,
            containerSize: configuration.containerSize,
            viewerVideoSize: configuration.videoSize
        )
    }

    @ViewBuilder
    private func focusedWindowResizeOverlay(containerSize: CGSize) -> some View {
        if viewModel.focusedWindowResizeState.isActive,
           let videoSize = renderedVideoSize {
            let interaction = viewModel.focusedWindowResizeState.interaction
            let usesUnclippedMoveFrame = interaction?.mode == .move
                && interaction?.binding.allowsRecoverableOffscreenMove == true
            let targetRect: CGRect? = interaction?.target.flatMap { target -> CGRect? in
                if usesUnclippedMoveFrame {
                    guard let full = target.unclippedNormalizedFrame else { return nil }
                    return AspectFitCoordinateMapper.unclippedViewRect(
                        forNormalizedRect: Self.cgRect(from: full),
                        containerSize: containerSize,
                        videoSize: videoSize
                    )
                }
                return AspectFitCoordinateMapper.viewRect(
                    forNormalizedRect: Self.cgRect(from: target.normalizedFrame),
                    containerSize: containerSize,
                    videoSize: videoSize
                )
            }
            let ghostRect = focusedWindowResizeGhostFrame.flatMap {
                usesUnclippedMoveFrame
                    ? AspectFitCoordinateMapper.unclippedViewRect(
                        forNormalizedRect: $0,
                        containerSize: containerSize,
                        videoSize: videoSize
                    )
                    : AspectFitCoordinateMapper.viewRect(
                        forNormalizedRect: $0,
                        containerSize: containerSize,
                        videoSize: videoSize
                    )
            }
            FocusedWindowResizeOverlay(
                targetRect: targetRect,
                ghostRect: ghostRect,
                showsResizeQuadrants: interaction?.mode == .resize,
                clipRect: AspectFitCoordinateMapper.visibleVideoRect(
                    containerSize: containerSize,
                    videoSize: videoSize
                )
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func focusedWindowControls(containerSize: CGSize) -> some View {
        if remoteInputPresentationAvailability.keyboard,
           let controlVideoSize = renderedVideoSize
                ?? viewModel.focusedWindowResizeState.interaction?.binding.viewerVideoSize {
            VStack(alignment: .trailing, spacing: 8) {
                if let interaction = viewModel.focusedWindowResizeState.interaction,
                   interaction.mode == .move {
                    Text(interaction.pending != nil
                        || interaction.awaitingPresentedVideoSize != nil
                        ? "Updating window…"
                        : interaction.target == nil
                            ? "Tap a window to select it"
                            : "Hold and drag anywhere to move. Tap another window to select it.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("worldwideFocusedWindowMoveHint")
                }
                HStack(spacing: 10) {
                    focusedWindowButton(
                        mode: .move,
                        containerSize: containerSize,
                        videoSize: controlVideoSize
                    )
                    focusedWindowButton(
                        mode: .resize,
                        containerSize: containerSize,
                        videoSize: controlVideoSize
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func focusedWindowButton(
        mode: FocusedWindowInteractionMode,
        containerSize: CGSize,
        videoSize: CGSize
    ) -> some View {
        let isActive = viewModel.focusedWindowResizeState.interaction?.mode == mode
        let isPresentationFenced = viewModel.focusedWindowResizeState.interaction?
            .awaitingPresentationToken != nil
        let isAvailable = mode == .move
            ? viewModel.isFocusedWindowMoveAvailable
            : viewModel.isFocusedWindowResizeAvailable
        // While Move awaits a newly presented resolution, retain only its Done action. The
        // fallback video size is deliberately not permission to start another interaction mode.
        if isActive || (isAvailable && !isPresentationFenced) {
            Button {
                focusedWindowResizeGhostFrame = nil
                if isActive {
                    viewModel.cancelFocusedWindowResize()
                } else if mode == .move {
                    _ = viewModel.beginFocusedWindowMove(
                        for: lease,
                        containerSize: containerSize,
                        viewerVideoSize: videoSize
                    )
                } else {
                    _ = viewModel.beginFocusedWindowResize(
                        for: lease,
                        containerSize: containerSize,
                        viewerVideoSize: videoSize
                    )
                }
            } label: {
                Label(
                    isActive ? "Done" : mode == .move ? "Move" : "Resize",
                    systemImage: isActive
                        ? "checkmark"
                        : mode == .move ? "arrow.up.and.down.and.arrow.left.and.right"
                            : "arrow.up.left.and.arrow.down.right"
                )
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(isActive ? .green : .blue)
            .controlSize(.large)
            .accessibilityIdentifier(mode == .move
                ? "worldwideFocusedWindowMoveButton" : "worldwideFocusedWindowResizeButton")
            .accessibilityHint(
                isActive
                    ? "Ends window interaction mode"
                    : mode == .move ? "Select a Mac window, then hold and drag anywhere to move it"
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

    private static func cgRect(
        from rect: WebRTCWindowMoveUnclippedNormalizedRect
    ) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    static func focusedWindowMovePreviewFrame(
        target: FocusedWindowInteractionTarget,
        start: CGPoint,
        end: CGPoint,
        allowsRecoverableOffscreen: Bool
    ) -> CGRect? {
        let original: CGRect
        if allowsRecoverableOffscreen {
            guard let full = target.unclippedNormalizedFrame else { return nil }
            original = cgRect(from: full)
        } else {
            original = cgRect(from: target.normalizedFrame)
        }
        return FocusedWindowMoveGeometry.proposedFrame(
            original: original,
            start: start,
            end: end,
            displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            allowsRecoverableOffscreen: allowsRecoverableOffscreen
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
        let pendingMode: RemotePointerGestureInteractionMode = interaction.mode == .move
            ? .focusedWindowMovePending : .focusedWindowResizePending
        guard binding.lease == lease,
              binding.inputSessionID == capability.inputSessionID,
              binding.screenRequestID == capability.screenRequestID,
              binding.trackIdentity == ObjectIdentifier(track),
              binding.containerSize == containerSize,
              binding.viewerVideoSize == videoSize else {
            return pendingMode
        }
        if interaction.pending != nil || interaction.awaitingPresentedVideoSize != nil {
            return pendingMode
        }
        guard let target = interaction.target,
              let targetViewFrame = AspectFitCoordinateMapper.viewRect(
                  forNormalizedRect: Self.cgRect(from: target.normalizedFrame),
                  containerSize: containerSize,
                  videoSize: videoSize
              ) else {
            return interaction.mode == .move
                ? .focusedWindowMove(target: nil) : .focusedWindowResize(target: nil)
        }
        let gestureTarget = RemotePointerResizeTarget(
            generation: target.generation,
            viewFrame: targetViewFrame
        )
        return interaction.mode == .move
            ? .focusedWindowMove(target: gestureTarget)
            : .focusedWindowResize(target: gestureTarget)
    }

    private var remoteInputAccessibilityLabel: String {
        if viewModel.focusedWindowResizeState.interaction?.mode == .move {
            return "Move mode. Tap a window to select it, then hold and drag anywhere to move it."
        }
        return switch (
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

    /// Native cover/freshness resets report zero without a typed decoder-format event. They must
    /// still revoke pointer geometry while leaving the independently authenticated keyboard and
    /// any safely fenced Move selection to their own lifecycle owners.
    static func videoSizeCallbackRevokesPresentedGeometry(_ size: CGSize) -> Bool {
        size == .zero
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

struct FocusedWindowResizeOverlay: View {
    let targetRect: CGRect?
    let ghostRect: CGRect?
    let showsResizeQuadrants: Bool
    let clipRect: CGRect?

    var body: some View {
        ZStack {
            if let targetRect {
                Path(targetRect)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    .shadow(color: .black.opacity(0.8), radius: 2)
                if showsResizeQuadrants {
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
        .clipShape(FocusedWindowOverlayClipShape(clipRect: clipRect))
    }
}

private struct FocusedWindowOverlayClipShape: Shape {
    let clipRect: CGRect?

    func path(in rect: CGRect) -> Path {
        Path(clipRect ?? rect)
    }
}
