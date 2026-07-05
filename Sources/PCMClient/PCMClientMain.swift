import Foundation
import Network
import Streaming

@main
struct PCMClientMain {
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
