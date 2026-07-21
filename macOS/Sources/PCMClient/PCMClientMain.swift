import Foundation
import Network
import Streaming

/// Entry point for the non-playing PCM wire-protocol validator.
@main
struct PCMClientMain {
    /// Runs one bounded validation session; configuration/runtime failures exit nonzero.
    static func main() async {
        do {
            let options = try PCMClientOptions.parse(CommandLine.arguments)
            if options.showHelp {
                print(PCMClientOptions.usage)
                return
            }

            let client = try PCMClient(host: options.host, port: options.port, authToken: options.authToken)
            let report = try await client.run(maxPackets: options.maxPackets)
            print(report.render())
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
