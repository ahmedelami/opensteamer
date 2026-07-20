import SwiftUI

struct WorldwideScreenViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: WorldwideSessionViewModel
    let lease: WorldwideScreenPresentationLease
    let dismissPresentation: (WorldwideScreenPresentationLease) -> Void
    @State private var remoteVideoSize = CGSize.zero
    @State private var allowsRemoteInputPresentation = true
    @State private var primaryDragContext: PrimaryDragContext?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                header

                GeometryReader { geometry in
                    if allowsRemoteScreenRendering {
                        WebRTCRemoteScreenView(
                            track: viewModel.remoteVideoTrack,
                            onVideoSizeChanged: { remoteVideoSize = $0 }
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
                                          let inputSessionID = viewModel.remoteInputCapability?.inputSessionID else {
                                        return
                                    }
                                    primaryDragContext = PrimaryDragContext(
                                        inputSessionID: inputSessionID,
                                        containerSize: geometry.size,
                                        videoSize: remoteVideoSize
                                    )
                                }
                                .onEnded { value in
                                    defer { primaryDragContext = nil }
                                    guard case .second(true, let drag?) = value,
                                          let context = primaryDragContext,
                                          context.inputSessionID == viewModel.remoteInputCapability?.inputSessionID,
                                          context.containerSize == geometry.size,
                                          context.videoSize == remoteVideoSize else {
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
                .accessibilityIdentifier("worldwideMacScreenVideo")

                status

                Button {
                    hideAndDismiss()
                } label: {
                    Label("Hide Screen", systemImage: "rectangle.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("hideWorldwideMacScreen")
            }

            RemoteKeyboardInputView(
                inputAvailable: effectiveRemoteInputAvailable,
                focusGeneration: viewModel.focusedInputGeneration,
                isSecure: viewModel.focusedInputIsSecure,
                onInsertText: viewModel.sendRemoteText,
                onDeleteBackward: viewModel.sendRemoteBackspace,
                onReturn: viewModel.sendRemoteReturn
            )
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
        }
        .onChange(of: remoteVideoSize) {
            primaryDragContext = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Screen")
                    .font(.headline)
                Text(viewModel.remoteDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                hideAndDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("Hide Screen")
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var status: some View {
        VStack(spacing: 6) {
            Text(viewModel.stateText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

            Text(viewModel.routeText == "Unknown" ? "Finding best route" : viewModel.routeText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if effectiveRemoteInputAvailable {
                Label(
                    viewModel.isRemotePrimaryDragAvailable
                        ? "Tap to click · Hold and drag to select or move"
                        : "Touch control enabled",
                    systemImage: "hand.tap"
                )
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("worldwideRemoteInputEnabled")
            }

            if let lastError = viewModel.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .accessibilityIdentifier("worldwideMacScreenStatus")
    }

    private func hideAndDismiss() {
        allowsRemoteInputPresentation = false
        let claimed = viewModel.beginPassiveScreenTeardown(for: lease) {
            dismissPresentation(lease)
        }
        if !claimed {
            dismissPresentation(lease)
        }
    }

    private func rejectPresentationAndDismiss() {
        allowsRemoteInputPresentation = false
        _ = viewModel.beginPassiveScreenTeardown(for: lease)
        dismissPresentation(lease)
    }

    private func forwardTap(_ location: CGPoint, containerSize: CGSize) {
        guard effectiveRemoteInputAvailable,
              let normalizedPoint = AspectFitCoordinateMapper.normalizedPoint(
                for: location,
                containerSize: containerSize,
                videoSize: remoteVideoSize
              ) else {
            return
        }
        viewModel.sendRemoteTap(normalizedPoint: normalizedPoint)
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
            endNormalizedPoint: endpoints.end
        )
    }

    private var effectiveRemoteInputAvailable: Bool {
        viewModel.remoteInputIsAvailable(for: lease)
            && allowsRemoteInputPresentation
            && scenePhase == .active
    }

    private var allowsRemoteScreenRendering: Bool {
        Self.allowsScreenRendering(
            in: scenePhase,
            allowsPresentation: allowsRemoteInputPresentation,
            isScreenVisible: viewModel.screenPresentationIsVisible(lease)
        )
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

private struct PrimaryDragContext: Equatable {
    let inputSessionID: UUID
    let containerSize: CGSize
    let videoSize: CGSize
}
