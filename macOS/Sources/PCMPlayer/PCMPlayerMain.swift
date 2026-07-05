import ClientCore
import Foundation

@main
struct PCMPlayerMain {
    static func main() async {
        do {
            let options = try PCMPlayerOptions.parse(CommandLine.arguments)
            if options.showHelp {
                print(PCMPlayerOptions.usage)
                return
            }

            let session = StreamSession()
            let report = try await session.run(
                host: options.host,
                port: options.port,
                authToken: options.authToken,
                duration: options.duration,
                latencyMilliseconds: options.latencyMilliseconds,
                maxPackets: options.maxPackets
            )
            print(report.render())
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
