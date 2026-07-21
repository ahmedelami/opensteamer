import SwiftUI

/// Top-level tab shell for discovery, playback, and diagnostics.
///
/// Scene transitions are forwarded to both the local-stream and worldwide-session owners because
/// their media policies differ: local discovery may pause while worldwide audio can remain active
/// under the Background Audio entitlement.
struct ContentView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                BrowserView()
            }
            .tabItem {
                Label("Servers", systemImage: "antenna.radiowaves.left.and.right")
            }

            NavigationStack {
                PlayerView()
            }
            .tabItem {
                Label("Player", systemImage: "waveform")
            }

            NavigationStack {
                DiagnosticsView()
            }
            .tabItem {
                Label("Diagnostics", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
        }
        .task {
            // Discovery is idempotent, so tying it to the view task also covers root recreation.
            viewModel.startBrowsing()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.handleAppBecameActive()
                worldwideViewModel.handleAppBecameActive()
            case .inactive:
                viewModel.handleAppBecameInactive()
                worldwideViewModel.handleAppBecameInactive()
            case .background:
                viewModel.handleAppEnteredBackground()
                worldwideViewModel.handleAppEnteredBackground()
            @unknown default:
                break
            }
        }
    }
}
