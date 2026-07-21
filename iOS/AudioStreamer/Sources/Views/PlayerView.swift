import SwiftUI

/// Playback status and screen-presentation launcher for the current local or worldwide session.
/// Worldwide full-screen presentation is keyed by an ownership lease so replacement sessions and
/// delayed dismissals cannot hide or control a newer screen.
struct PlayerView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @State private var showsMacScreen = false
    @State private var worldwideScreenLease: WorldwideScreenPresentationLease?

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

            Section("Mac Screen") {
                Button {
                    showsMacScreen = true
                } label: {
                    Label("View Mac Screen", systemImage: "rectangle.inset.filled.and.person.filled")
                }
                .disabled(viewModel.screenVideoConnectionDescriptor == nil)
                .accessibilityIdentifier("viewMacScreen")

                if viewModel.selectedServer != nil,
                   viewModel.screenVideoConnectionDescriptor == nil {
                    Text("Screen viewing currently requires a direct Mac connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if worldwideViewModel.hasActiveSession {
                Section("Worldwide Mac Screen") {
                    LabeledContent("State", value: worldwideViewModel.stateText)
                    LabeledContent("Route", value: worldwideViewModel.routeText)
                    LabeledContent("Audio", value: worldwideViewModel.audioStateText)

                    if let acknowledgement =
                        worldwideViewModel.screenAcknowledgementOracle {
                        Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Mac screen acknowledgement")
                        .accessibilityValue(acknowledgement.accessibilityValue)
                        .accessibilityIdentifier("worldwideScreenAcknowledgementOracle")
                    }

                    if let audioError = worldwideViewModel.audioError {
                        Label(audioError, systemImage: "speaker.slash")
                            .foregroundStyle(.orange)
                    }

                    if worldwideViewModel.canResumeAudioPlayback {
                        Button {
                            worldwideViewModel.resumeAudioPlayback()
                        } label: {
                            Label(
                                worldwideViewModel.audioRecoveryButtonTitle,
                                systemImage: "play.fill"
                            )
                        }
                    }

                    Button {
                        worldwideScreenLease = worldwideViewModel.issueScreenPresentationLease()
                    } label: {
                        Label("View Mac Screen", systemImage: "rectangle.connected.to.line.below")
                    }
                    .disabled(!worldwideViewModel.canViewScreen)
                    .accessibilityIdentifier("viewWorldwideMacScreen")

                    if !worldwideViewModel.canViewScreen {
                        Text("Screen viewing becomes available after the secure WebRTC control channel connects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        if let lease = worldwideScreenLease {
                            _ = worldwideViewModel.beginPassiveScreenTeardown(for: lease)
                            dismissWorldwideScreen(lease)
                        }
                        worldwideViewModel.disconnect()
                    } label: {
                        Label("Disconnect Remote Mac", systemImage: "stop.fill")
                    }
                }
            }

            if viewModel.selectedServer != nil {
                Section {
                    Button(role: .destructive) {
                        viewModel.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "stop.fill")
                    }
                }
            }
        }
        .navigationTitle("Player")
        .fullScreenCover(isPresented: $showsMacScreen) {
            if let descriptor = viewModel.screenVideoConnectionDescriptor {
                ScreenViewerView(descriptor: descriptor)
            }
        }
        .fullScreenCover(item: $worldwideScreenLease) { lease in
            WorldwideScreenViewerView(
                lease: lease,
                dismissPresentation: dismissWorldwideScreen
            )
                .environmentObject(worldwideViewModel)
        }
        .onChange(of: viewModel.selectedServer) { _, selectedServer in
            if selectedServer == nil {
                showsMacScreen = false
            }
        }
        .onChange(of: worldwideViewModel.canViewScreen) { _, canViewScreen in
            if !canViewScreen, let lease = worldwideScreenLease {
                dismissWorldwideScreen(lease)
            }
        }
    }

    private func dismissWorldwideScreen(_ lease: WorldwideScreenPresentationLease) {
        // Dismiss only the presentation represented by this callback; a new cover may already own
        // a replacement lease by the time asynchronous remote Hide completes.
        guard worldwideScreenLease == lease else { return }
        worldwideViewModel.retireScreenPresentationLease(lease)
        worldwideScreenLease = nil
    }
}

private extension Float {
    var dbFSDescription: String {
        guard self > 0 else { return "-inf dBFS" }
        return (20 * log10(Double(self))).formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
