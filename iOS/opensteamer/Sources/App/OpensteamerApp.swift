import RemoteSessionCore
import SwiftUI

/// Compile-time switch that replaces the production root with a deliberately inert host for
/// install-over-update Keychain validation. Keeping the test host empty prevents normal startup
/// hydration from changing the credentials that the validation target is about to inspect.
enum OpensteamerAppRootMode {
    #if OPENSTEAMER_UPDATE_VALIDATION_HOST
    static let isPhysicalUpdateValidationHost = true
    #else
    static let isPhysicalUpdateValidationHost = false
    #endif
}

/// Application composition root for the iPhone viewer.
///
/// The production path creates each long-lived session owner exactly once and injects those
/// owners through SwiftUI's environment. The validation-host path intentionally skips all of
/// that work so its test bundle can observe persisted state before the app touches it.
@main
struct OpensteamerApp: App {
    #if OPENSTEAMER_UPDATE_VALIDATION_HOST
    // Application-hosted update tests must observe Keychain before production hydration runs.
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
    #else
    @StateObject private var viewModel = StreamSessionViewModel()
    @StateObject private var worldwideViewModel = WorldwideSessionViewModel()
    @StateObject private var worldwideConnection: WorldwideViewerConnectionCoordinator

    init() {
        let telemetry = LocalConnectionTelemetryJournal.applicationSupport(
            component: "ios-viewer"
        )
        _worldwideConnection = StateObject(
            wrappedValue: WorldwideViewerConnectionCoordinator(
                connectionTelemetry: telemetry
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(worldwideViewModel)
                .environmentObject(worldwideConnection)
        }
    }
    #endif
}
