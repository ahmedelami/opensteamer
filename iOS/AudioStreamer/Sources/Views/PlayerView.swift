import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @State private var showsMacScreen = false
    @State private var showsWorldwideMacScreen = false

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

                    Button {
                        showsWorldwideMacScreen = true
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
                        showsWorldwideMacScreen = false
                        worldwideViewModel.disconnect()
                    } label: {
                        Label("Disconnect Remote Mac", systemImage: "stop.fill")
                    }
                }
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
        .fullScreenCover(isPresented: $showsMacScreen) {
            if let descriptor = viewModel.screenVideoConnectionDescriptor {
                ScreenViewerView(descriptor: descriptor)
            }
        }
        .fullScreenCover(isPresented: $showsWorldwideMacScreen) {
            WorldwideScreenViewerView()
                .environmentObject(worldwideViewModel)
        }
        .onChange(of: viewModel.selectedServer) { _, selectedServer in
            if selectedServer == nil {
                showsMacScreen = false
            }
        }
        .onChange(of: worldwideViewModel.canViewScreen) { _, canViewScreen in
            if !canViewScreen {
                showsWorldwideMacScreen = false
            }
        }
    }
}

private extension Float {
    var dbFSDescription: String {
        guard self > 0 else { return "-inf dBFS" }
        return (20 * log10(Double(self))).formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
