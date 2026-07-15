import SwiftUI

struct WorldwideScreenViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: WorldwideSessionViewModel
    @State private var remoteVideoSize = CGSize.zero
    @State private var allowsRemoteInputPresentation = true

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
            let shown = await viewModel.setScreenVisible(true)
            guard shown, Self.allowsScreenPresentation(in: scenePhase) else {
                rejectPresentationAndDismiss()
                return
            }
        }
        .onDisappear {
            allowsRemoteInputPresentation = false
            viewModel.beginPassiveScreenTeardown()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            hideAndDismiss()
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
                Label("Touch control enabled", systemImage: "hand.tap")
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
        viewModel.beginPassiveScreenTeardown {
            await viewModel.setScreenVisible(false)
            dismiss()
        }
    }

    private func rejectPresentationAndDismiss() {
        allowsRemoteInputPresentation = false
        viewModel.beginPassiveScreenTeardown()
        dismiss()
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

    private var effectiveRemoteInputAvailable: Bool {
        viewModel.isRemoteInputAvailable
            && allowsRemoteInputPresentation
            && scenePhase == .active
    }

    private var allowsRemoteScreenRendering: Bool {
        Self.allowsScreenRendering(
            in: scenePhase,
            allowsPresentation: allowsRemoteInputPresentation,
            isScreenVisible: viewModel.isScreenVisible
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
