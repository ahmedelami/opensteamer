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

            Section("Renderer") {
                MetricRow(title: "Output Route", value: viewModel.audioRouteText)
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
