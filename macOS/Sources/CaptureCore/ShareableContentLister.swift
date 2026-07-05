import Foundation
import ScreenCaptureKit

public struct ShareableContentLister {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func printDisplays() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if content.displays.isEmpty {
            print("No displays found")
            return
        }

        for display in content.displays {
            print("display id=\(display.displayID) width=\(display.width) height=\(display.height)")
        }
    }

    public func printApplications() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if content.applications.isEmpty {
            print("No applications found")
            return
        }

        for app in content.applications.sorted(by: { $0.applicationName < $1.applicationName }) {
            print("app pid=\(app.processID) name=\"\(app.applicationName)\"")
        }
    }
}
