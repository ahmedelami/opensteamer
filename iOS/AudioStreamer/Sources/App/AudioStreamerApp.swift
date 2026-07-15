import SwiftUI

@main
struct AudioStreamerApp: App {
    @StateObject private var viewModel = StreamSessionViewModel()
    @StateObject private var worldwideViewModel = WorldwideSessionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(worldwideViewModel)
        }
    }
}
