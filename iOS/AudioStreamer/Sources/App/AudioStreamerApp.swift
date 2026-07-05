import SwiftUI

@main
struct AudioStreamerApp: App {
    @StateObject private var viewModel = StreamSessionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
