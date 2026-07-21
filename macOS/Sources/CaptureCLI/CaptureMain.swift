import CaptureCore
import Foundation
import Utilities

/// Entry point for bounded WAV capture and ScreenCaptureKit discovery commands.
@main
struct CaptureCLI {
    /// Executes exactly one listing or capture operation; failures exit nonzero.
    static func main() async {
        do {
            let options = try CLIOptions.parse(CommandLine.arguments)

            if options.showHelp {
                print(CLIOptions.usage)
                return
            }

            let logger = ConsoleLogger(verbose: options.verbose)
            let contentLister = ShareableContentLister(logger: logger)

            if options.listDisplays {
                try await contentLister.printDisplays()
                return
            }

            if options.listApps {
                try await contentLister.printApplications()
                return
            }

            let outputURL = options.outputURL
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("capture-\(Timestamp.fileSafeNow()).wav")

            let manager = CaptureManager(
                duration: options.duration,
                outputURL: outputURL,
                displayID: options.displayID,
                logger: logger
            )

            let report = try await manager.run()
            print(report.render())
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
