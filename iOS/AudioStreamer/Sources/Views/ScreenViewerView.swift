import SwiftUI

struct ScreenViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ScreenSessionViewModel

    init(descriptor: ScreenVideoConnectionDescriptor) {
        _viewModel = StateObject(wrappedValue: ScreenSessionViewModel(descriptor: descriptor))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                header

                Spacer(minLength: 0)

                SampleBufferScreenView(renderer: viewModel.renderer)
                    .aspectRatio(viewModel.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .overlay {
                        if viewModel.frameCount == 0 {
                            ProgressView()
                                .tint(.white)
                                .accessibilityLabel(viewModel.stateText)
                        }
                    }
                    .accessibilityIdentifier("macScreenVideo")

                status

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Label("Hide Screen", systemImage: "rectangle.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("hideMacScreen")
            }
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Screen")
                    .font(.headline)
                Text(viewModel.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
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

            if let lastError = viewModel.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .accessibilityIdentifier("macScreenStatus")
    }
}
