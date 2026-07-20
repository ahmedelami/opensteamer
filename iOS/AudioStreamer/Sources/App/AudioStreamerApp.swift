import SwiftUI

enum AudioStreamerAppRootMode {
    #if AUDIOSTREAMER_UPDATE_VALIDATION_HOST
    static let isPhysicalUpdateValidationHost = true
    #else
    static let isPhysicalUpdateValidationHost = false
    #endif
}

@main
struct AudioStreamerApp: App {
    #if AUDIOSTREAMER_UPDATE_VALIDATION_HOST
    // Application-hosted update tests must observe Keychain before production hydration runs.
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
    #else
    @StateObject private var viewModel = StreamSessionViewModel()
    @StateObject private var worldwideViewModel = WorldwideSessionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(worldwideViewModel)
        }
    }
    #endif
}
