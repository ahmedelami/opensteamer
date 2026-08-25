import SwiftUI

/// Full-screen viewer for the legacy sample-buffer screen stream.
/// The view owns its session model for exactly the presentation lifetime, starting transport when
/// presented and stopping it on every dismissal path.
struct ScreenViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ScreenSessionViewModel

    init(descriptor: ScreenVideoConnectionDescriptor) {
        _viewModel = StateObject(wrappedValue: ScreenSessionViewModel(descriptor: descriptor))
    }

    var body: some View {
        FullscreenViewerLayout(
            backAccessibilityIdentifier: "hideMacScreen",
            backAccessibilityLabel: "Back to Player",
            onBack: { dismiss() }
        ) {
            GeometryReader { geometry in
                SampleBufferScreenView(renderer: viewModel.renderer)
                    .aspectRatio(viewModel.aspectRatio, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(.black)
                    .overlay {
                        if viewModel.frameCount == 0 {
                            ProgressView()
                                .tint(.white)
                                .accessibilityLabel(viewModel.stateText)
                        }
                    }
                    .accessibilityIdentifier("macScreenVideo")
            }
        } statusOverlay: {
            VStack(spacing: 4) {
                Text(viewModel.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(viewModel.stateText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)

                if let lastError = viewModel.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
            .accessibilityIdentifier("macScreenStatus")
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

}

/// Edge-to-edge viewer shell shared by the local and worldwide screen paths.
///
/// The streamed image owns the complete display surface. Navigation is an overlay instead of a
/// layout row, so the user always has an obvious exit without reducing the remote-screen viewport.
struct FullscreenViewerLayout<Content: View, StatusOverlay: View>: View {
    let backAccessibilityIdentifier: String
    let backAccessibilityLabel: String
    let onBack: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let statusOverlay: StatusOverlay

    init(
        backAccessibilityIdentifier: String,
        backAccessibilityLabel: String,
        onBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder statusOverlay: () -> StatusOverlay
    ) {
        self.backAccessibilityIdentifier = backAccessibilityIdentifier
        self.backAccessibilityLabel = backAccessibilityLabel
        self.onBack = onBack
        self.content = content()
        self.statusOverlay = statusOverlay()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            statusOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.backward")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(backAccessibilityLabel)
                    .accessibilityIdentifier(backAccessibilityIdentifier)

                    Spacer()
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .statusBarHidden(true)
    }
}
