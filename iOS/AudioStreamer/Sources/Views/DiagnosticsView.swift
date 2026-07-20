import RemoteSessionCore
import SwiftUI
import WebRTCTransport

struct DiagnosticsView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @EnvironmentObject private var worldwideConnection: WorldwideViewerConnectionCoordinator

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

            Section("Connection Timeline") {
                MetricRow(
                    title: "Local Journal",
                    value: worldwideConnection.connectionTelemetrySnapshot.persistenceHealthy
                        ? "Healthy"
                        : "Persistence unavailable"
                )
                MetricRow(
                    title: "Retained Events",
                    value: "\(worldwideConnection.connectionTelemetrySnapshot.events.count)"
                )
                if worldwideConnection.connectionTelemetrySnapshot.droppedEventCount > 0 {
                    MetricRow(
                        title: "Older Events Dropped",
                        value: "\(worldwideConnection.connectionTelemetrySnapshot.droppedEventCount)"
                    )
                }
                if worldwideConnection.connectionTelemetrySnapshot.events.isEmpty {
                    Text("No connection attempts recorded yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        Array(worldwideConnection.connectionTelemetrySnapshot.events.suffix(20).reversed())
                    ) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.stage.rawValue)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text(event.timestamp, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(connectionEventDetail(event))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Stored only on this device; no automatic telemetry upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func connectionEventDetail(_ event: ConnectionTelemetryEvent) -> String {
        var details: [String] = []
        if event.stage == .viewerWorkerWaitingForHost {
            details.append("Worker authenticated the iPhone; paired Mac was not present")
        }
        if let retry = event.retryOrdinal {
            details.append("retry \(retry)")
        }
        if let failure = event.failure {
            details.append("failure \(failure.rawValue)")
        }
        if let terminal = event.terminal {
            details.append("terminal \(terminal.rawValue)")
        }
        if let attempt = event.attemptReference {
            details.append("attempt \(attempt.rawValue.prefix(8))")
        }
        return details.isEmpty ? "Connection transition" : details.joined(separator: " · ")
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
