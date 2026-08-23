import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Prints ScreenCaptureKit display and application identifiers for CLI selection.
public struct ShareableContentLister {
    private let logger: Logger

    /// Creates a lister that shares the caller's logging dependency.
    public init(logger: Logger) {
        self.logger = logger
    }

    /// Prints every currently shareable display and its pixel dimensions.
    public func printDisplays() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if content.displays.isEmpty {
            print("No displays found")
            return
        }

        for display in content.displays {
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                print(
                    "display id=\(display.displayID) "
                        + "width=\(display.width) height=\(display.height) "
                        + "pixels=\(mode.pixelWidth)x\(mode.pixelHeight)"
                )
            } else {
                print(
                    "display id=\(display.displayID) "
                        + "width=\(display.width) height=\(display.height) pixels=unavailable"
                )
            }
        }
    }

    /// Prints shareable applications in a deterministic, name-sorted order.
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
