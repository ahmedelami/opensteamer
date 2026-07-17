import SwiftUI
import WebRTCTransport

struct DiagnosticsView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel

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

            Section("Worldwide Screen") {
                MetricRow(title: "State", value: worldwideViewModel.stateText)
                MetricRow(title: "ICE", value: worldwideViewModel.iceStateText)
                MetricRow(title: "Route", value: worldwideViewModel.routeText)
                MetricRow(
                    title: "Round Trip",
                    value: worldwideViewModel.statistics?.currentRoundTripTime
                        .map { $0.formatted(.number.precision(.fractionLength(3))) + " s" }
                        ?? "Unknown"
                )
                MetricRow(
                    title: "Video",
                    value: worldwideVideoDescription
                )
            }

            Section("Worldwide Audio RTP") {
                if let audio = worldwideViewModel.statistics?.inboundAudio {
                    MetricRow(title: "Packets", value: audio.packets.metricDescription)
                    MetricRow(title: "Lost", value: audio.packetsLost.metricDescription)
                    MetricRow(
                        title: "Discarded",
                        value: audio.packetsDiscarded.metricDescription
                    )
                    MetricRow(title: "Network Jitter", value: milliseconds(audio.jitter))
                    MetricRow(
                        title: "Jitter Buffer",
                        value: averageJitterBufferDelay(audio)
                    )
                    MetricRow(
                        title: "Concealed Samples",
                        value: audio.concealedSamples.metricDescription
                    )
                    MetricRow(
                        title: "Concealment Events",
                        value: audio.concealmentEvents.metricDescription
                    )
                    MetricRow(
                        title: "Silent Concealment",
                        value: audio.silentConcealedSamples.metricDescription
                    )
                    MetricRow(
                        title: "Inserted / Removed",
                        value: "\(audio.insertedSamplesForDeceleration.metricDescription) / "
                            + audio.removedSamplesForAcceleration.metricDescription
                    )
                } else {
                    Text("No inbound audio statistics")
                        .foregroundStyle(.secondary)
                }
            }

            if let lastDiagnostic = worldwideViewModel.lastDiagnostic {
                Section("Worldwide Last Diagnostic") {
                    Text(lastDiagnostic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let audioDiagnostic = worldwideViewModel.audioDiagnostic {
                Section("Worldwide Audio Diagnostic") {
                    Text(audioDiagnostic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let candidateError = worldwideViewModel.lastICECandidateError {
                Section("Worldwide ICE Probe") {
                    MetricRow(title: "Server", value: candidateError.url)
                    MetricRow(title: "Code", value: "\(candidateError.errorCode)")
                    MetricRow(
                        title: "Local Endpoint",
                        value: candidateError.address.isEmpty
                            ? "Unknown"
                            : "\(candidateError.address):\(candidateError.port)"
                    )
                    Text(candidateError.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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

    private var worldwideVideoDescription: String {
        guard let video = worldwideViewModel.statistics?.inboundVideo else {
            return "No frames"
        }
        let size = if let width = video.frameWidth, let height = video.frameHeight {
            "\(width)×\(height)"
        } else {
            "Unknown size"
        }
        guard let framesPerSecond = video.framesPerSecond else { return size }
        return "\(size) · \(framesPerSecond.formatted(.number.precision(.fractionLength(1)))) fps"
    }

    private func milliseconds(_ seconds: Double?) -> String {
        guard let seconds else { return "Unknown" }
        return (seconds * 1_000).formatted(
            .number.precision(.fractionLength(1))
        ) + " ms"
    }

    private func averageJitterBufferDelay(_ audio: WebRTCAudioStatistics) -> String {
        guard let totalDelay = audio.jitterBufferDelay,
              let emittedCount = audio.jitterBufferEmittedCount,
              emittedCount > 0 else {
            return "Unknown"
        }
        return milliseconds(totalDelay / Double(emittedCount))
    }
}

private extension Optional where Wrapped: BinaryInteger {
    var metricDescription: String {
        map { String($0) } ?? "Unknown"
    }
}

private extension Float {
    var dbFSDescription: String {
        guard self > 0 else { return "-inf dBFS" }
        return (20 * log10(Double(self))).formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
