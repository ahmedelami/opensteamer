import ClientCore
import Foundation

/// Entry point for receiving and audibly playing the framed PCM stream.
@main
struct PCMPlayerMain {
    /// Runs one playback session; option or streaming failures exit nonzero.
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
