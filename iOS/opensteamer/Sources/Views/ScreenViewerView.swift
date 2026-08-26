import SwiftUI

/// Full-screen viewer for the legacy sample-buffer screen stream.
/// The view owns its session model for exactly the presentation lifetime, starting transport when
/// presented and stopping it on every dismissal path.
struct ScreenViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: ScreenSessionViewModel

    init(descriptor: ScreenVideoConnectionDescriptor) {
        _viewModel = StateObject(wrappedValue: ScreenSessionViewModel(descriptor: descriptor))
    }

    var body: some View {
        ZStack {
            FullscreenViewerLayout {
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
            }

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("\(viewModel.displayName), \(viewModel.stateText)")
                .accessibilityValue(viewModel.lastError ?? viewModel.stateText)
                .accessibilityIdentifier("macScreenStatus")
                .allowsHitTesting(false)
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            viewModel.stop()
            dismiss()
        }
    }

}

/// Edge-to-edge viewer shell shared by the local and worldwide screen paths.
///
/// The streamed image is the only visible content and owns the complete display surface.
struct FullscreenViewerLayout<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .statusBarHidden(true)
    }
}
