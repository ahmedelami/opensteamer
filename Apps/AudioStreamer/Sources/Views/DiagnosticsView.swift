import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel

    var body: some View {
        List {
            Section("Protocol") {
                MetricRow(title: "Framing Errors", value: "\(viewModel.metrics.framingErrors)")
                MetricRow(title: "Sequence Errors", value: "\(viewModel.metrics.sequenceErrors)")
                MetricRow(title: "Timestamp Errors", value: "\(viewModel.metrics.timestampErrors)")
            }

            Section("Audio Session") {
                MetricRow(title: "Output Route", value: viewModel.audioSessionSnapshot.outputRoute)
                MetricRow(title: "Input Route", value: viewModel.audioSessionSnapshot.inputRoute)
                MetricRow(title: "Category", value: viewModel.audioSessionSnapshot.category)
                MetricRow(title: "Mode", value: viewModel.audioSessionSnapshot.mode)
                MetricRow(title: "Policy", value: viewModel.audioSessionSnapshot.routeSharingPolicy)
                MetricRow(title: "Sample Rate", value: viewModel.audioSessionSnapshot.sampleRate)
                MetricRow(title: "IO Buffer", value: viewModel.audioSessionSnapshot.ioBufferDuration)
                MetricRow(title: "Secondary Audio", value: viewModel.audioSessionSnapshot.secondaryAudio)
                MetricRow(title: "Other Audio", value: viewModel.audioSessionSnapshot.otherAudio)
                MetricRow(title: "Last Event", value: viewModel.audioSessionSnapshot.lastEvent)
            }

            Section("Renderer") {
                MetricRow(title: "State", value: viewModel.rendererStateText)
                MetricRow(title: "Receive RMS", value: viewModel.metrics.audioRMS.dbFSDescription)
                MetricRow(title: "Receive Peak", value: viewModel.metrics.audioPeak.dbFSDescription)
                MetricRow(title: "Playback RMS", value: viewModel.metrics.playbackRMS.dbFSDescription)
                MetricRow(title: "Playback Peak", value: viewModel.metrics.playbackPeak.dbFSDescription)
                MetricRow(title: "Dropped Frames", value: "\(viewModel.metrics.droppedFrames)")
                MetricRow(title: "Underruns", value: "\(viewModel.metrics.underruns)")
            }

            if let lastError = viewModel.lastError {
                Section("Last Error") {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

private extension Float {
    var dbFSDescription: String {
        guard self > 0 else { return "-inf dBFS" }
        return (20 * log10(Double(self))).formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
