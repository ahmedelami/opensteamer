import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
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
            viewModel.startBrowsing()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewModel.handleAppBecameActive()
            case .inactive:
                viewModel.handleAppBecameInactive()
            case .background:
                viewModel.handleAppEnteredBackground()
            @unknown default:
                break
            }
        }
    }
}
