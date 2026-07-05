import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("State", value: viewModel.stateText)
                LabeledContent("Server", value: viewModel.selectedServer?.name ?? "None")
            }

            Section("Stream") {
                MetricRow(title: "Packets", value: "\(viewModel.metrics.packetsReceived)")
                MetricRow(title: "Bytes", value: "\(viewModel.metrics.bytesReceived)")
                MetricRow(title: "Receive RMS", value: viewModel.metrics.audioRMS.dbFSDescription)
                MetricRow(title: "Receive Peak", value: viewModel.metrics.audioPeak.dbFSDescription)
                MetricRow(title: "Playback RMS", value: viewModel.metrics.playbackRMS.dbFSDescription)
                MetricRow(title: "Playback Peak", value: viewModel.metrics.playbackPeak.dbFSDescription)
                MetricRow(title: "Queue", value: "\(viewModel.metrics.queueDepthFrames) frames")
                MetricRow(title: "Latency", value: viewModel.metrics.latencyEstimate.formatted(.number.precision(.fractionLength(3))) + " s")
                MetricRow(title: "Jitter", value: viewModel.metrics.networkJitterEstimate.formatted(.number.precision(.fractionLength(3))) + " s")
            }

            Section {
                Button(role: .destructive) {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                }
            }
        }
        .navigationTitle("Player")
    }
}

private extension Float {
    var dbFSDescription: String {
        guard self > 0 else { return "-inf dBFS" }
        return (20 * log10(Double(self))).formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
